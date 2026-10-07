# =========================================================================
# GitHub Issue → ComfyUI → 動画生成 → GitHub Pages → Issue Close
#
# 必要ファイル:
#
#   run_issues.ps1
#   workflows\minimax_h3.json
#
# Workflow JSONのルール:
#
#   プロンプトを入れる場所だけ
#
#       "__TARGET_PROMPT__"
#
#   にしてください。
#
# Seedは通常の数値でOKです。
# このスクリプトが RandomNoise ノードを探して自動的にランダム化します。
#
# 実行:
#
#   powershell -ExecutionPolicy Bypass -File .\run_issues.ps1
#
# またはWorkflowを指定:
#
#   powershell -ExecutionPolicy Bypass -File .\run_issues.ps1 `
#       -WorkflowJson ".\workflows\minimax_h3.json"
#
# =========================================================================

param(
    [string]$WorkflowJson = ".\workflows\video_minimax_h3_t2v.json"
)

# =========================================================================
# 設定
# =========================================================================

$GithubRepo = "mochi-contents-lab/makemovie"

$ComfyUrl = "http://127.0.0.1:8188"

$ComfyPromptUrl  = "$ComfyUrl/prompt"
$ComfyHistoryUrl = "$ComfyUrl/history"
$ComfySystemUrl  = "$ComfyUrl/system_stats"

$ComfyOutputDir = "F:\aiimg\StabilityMatrix\Data\Images\Text2Img\video"

$RepoVideoDir = "docs\videos"
$PagesFile = "docs\index.html"

# 生成確認間隔
$CheckIntervalSeconds = 300

# 最大待機時間
$MaxWaitSeconds = 3600

# 一度に取得するIssue数
$IssueLimit = 10

# プロンプト置換文字列
$PromptPlaceholder = "__TARGET_PROMPT__"

# 二重処理防止用のコメントマーカー
$SuccessMarker = "[COMFYUI-AUTO-COMPLETED]"

# =========================================================================
# UTF-8
# =========================================================================

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
}
catch {
}

$OutputEncoding = $Utf8NoBom

# =========================================================================
# 共通関数
# =========================================================================

function Write-Section {
    param(
        [string]$Text
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkGray
}

# =========================================================================
# GitHub CLI
# =========================================================================

function Invoke-GhJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = "gh"

    # 引数を安全に組み立てる
    $escapedArguments = @()

    foreach ($arg in $Arguments) {

        if ($arg -match '[\s"]') {

            $escaped = $arg.Replace('\', '\\').Replace('"', '\"')

            $escapedArguments += '"' + $escaped + '"'
        }
        else {
            $escapedArguments += $arg
        }
    }

    $psi.Arguments = $escapedArguments -join " "

    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {

        throw "gh command failed: $stderr"
    }

    return $stdout
}

# =========================================================================
# Workflow JSONを再帰的に処理
# =========================================================================

function Replace-PromptPlaceholder {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PromptText,

        [Parameter(Mandatory = $true)]
        [ref]$ReplacementCount
    )

    if ($null -eq $Object) {
        return
    }

    # 配列
    if ($Object -is [System.Collections.IList]) {

        for ($i = 0; $i -lt $Object.Count; $i++) {

            if ($Object[$i] -is [string]) {

                if ($Object[$i] -eq $PromptPlaceholder) {

                    $Object[$i] = $PromptText
                    $ReplacementCount.Value++
                }
            }
            else {

                Replace-PromptPlaceholder `
                    -Object $Object[$i] `
                    -PromptText $PromptText `
                    -ReplacementCount $ReplacementCount
            }
        }

        return
    }

    # オブジェクト
    if ($Object -is [PSCustomObject]) {

        foreach ($property in $Object.PSObject.Properties) {

            if ($property.Value -is [string]) {

                if ($property.Value -eq $PromptPlaceholder) {

                    $property.Value = $PromptText
                    $ReplacementCount.Value++
                }
            }
            else {

                Replace-PromptPlaceholder `
                    -Object $property.Value `
                    -PromptText $PromptText `
                    -ReplacementCount $ReplacementCount
            }
        }
    }
}

# =========================================================================
# RandomNoiseノードのSeedを変更
# =========================================================================

function Set-RandomSeed {
    param(
        [Parameter(Mandatory = $true)]
        $Workflow,

        [Parameter(Mandatory = $true)]
        [Int64]$Seed
    )

    $found = $false

    foreach ($property in $Workflow.PSObject.Properties) {

        $node = $property.Value

        if ($null -eq $node) {
            continue
        }

        if ($node.PSObject.Properties.Name -contains "class_type") {

            if ([string]$node.class_type -eq "RandomNoise") {

                if ($node.PSObject.Properties.Name -notcontains "inputs") {
                    throw "RandomNoiseノードにinputsがありません。"
                }

                if ($node.inputs.PSObject.Properties.Name -contains "noise_seed") {

                    $node.inputs.noise_seed = $Seed

                    Write-Host "RandomNoise Seedを変更: $Seed" -ForegroundColor DarkGray

                    $found = $true
                }
            }
        }
    }

    if (!$found) {

        throw @"
RandomNoise ノードがWorkflow JSON内に見つかりません。

このスクリプトはSeedを自動ランダム化するため、
Workflow JSONに RandomNoise ノードが必要です。
"@
    }
}

# =========================================================================
# ComfyUI History
# =========================================================================

function Get-ComfyHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptId
    )

    try {

        $url = "$ComfyHistoryUrl/$PromptId"

        return Invoke-RestMethod `
            -Uri $url `
            -Method Get `
            -ErrorAction Stop
    }
    catch {

        return $null
    }
}

# =========================================================================
# 動画出力をHistoryから探す
# =========================================================================

function Get-VideoOutputFromHistory {
    param(
        [Parameter(Mandatory = $true)]
        $History
    )

    if ($null -eq $History) {
        return $null
    }

    if ($History.PSObject.Properties.Name -notcontains "outputs") {
        return $null
    }

    foreach ($nodeProperty in $History.outputs.PSObject.Properties) {

        $nodeOutput = $nodeProperty.Value

        if ($null -eq $nodeOutput) {
            continue
        }

        # SaveVideoは環境によってimages配下に動画を返す
        if ($nodeOutput.PSObject.Properties.Name -contains "images") {

            foreach ($item in @($nodeOutput.images)) {

                if ($null -eq $item.filename) {
                    continue
                }

                $extension = [System.IO.Path]::GetExtension(
                    [string]$item.filename
                )

                if ($extension -match '(?i)^\.(mp4|webm|mov|mkv|avi)$') {

                    return [PSCustomObject]@{
                        Filename  = [string]$item.filename
                        Subfolder = [string]$item.subfolder
                        Type      = [string]$item.type
                        NodeId    = [string]$nodeProperty.Name
                    }
                }
            }
        }

        # 将来の形式用
        if ($nodeOutput.PSObject.Properties.Name -contains "videos") {

            foreach ($item in @($nodeOutput.videos)) {

                if ($null -eq $item.filename) {
                    continue
                }

                $extension = [System.IO.Path]::GetExtension(
                    [string]$item.filename
                )

                if ($extension -match '(?i)^\.(mp4|webm|mov|mkv|avi)$') {

                    return [PSCustomObject]@{
                        Filename  = [string]$item.filename
                        Subfolder = [string]$item.subfolder
                        Type      = [string]$item.type
                        NodeId    = [string]$nodeProperty.Name
                    }
                }
            }
        }
    }

    return $null
}

# =========================================================================
# HTMLエスケープ
# =========================================================================

function ConvertTo-HtmlSafe {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

# =========================================================================
# Issueの成功コメント確認
# =========================================================================

function Test-IssueAlreadyCompleted {
    param(
        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    try {

        $json = Invoke-GhJson @(
            "issue",
            "view",
            "$IssueNumber",
            "--repo",
            $GithubRepo,
            "--json",
            "comments"
        )

        $data = $json | ConvertFrom-Json

        foreach ($comment in @($data.comments)) {

            if ([string]$comment.body -like "*$SuccessMarker*") {

                return $true
            }
        }
    }
    catch {

        Write-Host "Issueコメントの確認に失敗したため、通常処理します。" -ForegroundColor Yellow
    }

    return $false
}

# =========================================================================
# Issue成功コメント
# =========================================================================

function Add-SuccessComment {
    param(
        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [string]$PromptId,

        [Parameter(Mandatory = $true)]
        [string]$VideoFileName
    )

    $comment = @"
$SuccessMarker

ComfyUI動画生成が正常に完了しました。

Prompt ID: $PromptId
Video: $VideoFileName

このIssueは自動処理済みです。
"@

    $result = & gh issue comment `
        $IssueNumber `
        --repo $GithubRepo `
        --body $comment 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "成功コメントの投稿に失敗しました: $result"
    }
}

# =========================================================================
# Issue Close
# =========================================================================

function Close-Issue {
    param(
        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [string]$PromptId,

        [Parameter(Mandatory = $true)]
        [string]$VideoFileName
    )

    $comment = @"
ComfyUIへのジョブ送信、動画生成、動画回収、GitHub Pages更新が正常に完了したため、このIssueを自動クローズしました。

Prompt ID: $PromptId
Video: $VideoFileName
"@

    $result = & gh issue close `
        $IssueNumber `
        --repo $GithubRepo `
        --comment $comment 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "Issue #$IssueNumber のクローズに失敗しました: $result"
    }
}

# =========================================================================
# 事前チェック
# =========================================================================

Write-Section "GitHub Issue → ComfyUI 自動動画生成"

Write-Host "Workflow JSON: $WorkflowJson" -ForegroundColor DarkGray

# Workflow存在確認
if (!(Test-Path -LiteralPath $WorkflowJson)) {

    Write-Error "Workflow JSONが見つかりません:"
    Write-Error $WorkflowJson

    exit 1
}

# ComfyUI確認
Write-Host ""
Write-Host "ComfyUI接続確認中..." -ForegroundColor Cyan

try {

    $null = Invoke-RestMethod `
        -Uri $ComfySystemUrl `
        -Method Get `
        -ErrorAction Stop

    Write-Host "ComfyUI: OK" -ForegroundColor Green
}
catch {

    Write-Error "ComfyUIに接続できません。"
    Write-Error "接続先: $ComfyUrl"

    exit 1
}

# 出力フォルダ
if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

    Write-Error "ComfyUI出力フォルダがありません:"
    Write-Error $ComfyOutputDir

    exit 1
}

# docs
if (!(Test-Path -LiteralPath "docs")) {

    New-Item `
        -ItemType Directory `
        -Path "docs" `
        -Force |
        Out-Null
}

if (!(Test-Path -LiteralPath $RepoVideoDir)) {

    New-Item `
        -ItemType Directory `
        -Path $RepoVideoDir `
        -Force |
        Out-Null
}

# =========================================================================
# Workflow JSON読み込み
# =========================================================================

Write-Host ""
Write-Host "Workflow JSONを読み込んでいます..." -ForegroundColor Cyan

try {

    $workflowText = [System.IO.File]::ReadAllText(
        (Resolve-Path $WorkflowJson),
        $Utf8NoBom
    )

    $baseWorkflow = $workflowText | ConvertFrom-Json
}
catch {

    Write-Error "Workflow JSONの読み込みに失敗しました: $_"
    exit 1
}

# API形式チェック
if ($baseWorkflow.PSObject.Properties.Name -contains "nodes") {

    Write-Error @"
指定されたJSONは通常のGUI Workflow形式のようです。

ComfyUIから
「Workflow → Export Workflow (API)」
または
「Save (API Format)」
でAPI形式JSONを書き出してください。
"@

    exit 1
}

# =========================================================================
# Prompt Placeholderチェック
# =========================================================================

$placeholderCount = 0

function Count-PromptPlaceholder {
    param(
        $Object
    )

    if ($null -eq $Object) {
        return
    }

    if ($Object -is [System.Collections.IList]) {

        foreach ($item in $Object) {

            if ($item -is [string]) {

                if ($item -eq $PromptPlaceholder) {
                    $script:placeholderCount++
                }
            }
            else {

                Count-PromptPlaceholder $item
            }
        }

        return
    }

    if ($Object -is [PSCustomObject]) {

        foreach ($property in $Object.PSObject.Properties) {

            if ($property.Value -is [string]) {

                if ($property.Value -eq $PromptPlaceholder) {
                    $script:placeholderCount++
                }
            }
            else {

                Count-PromptPlaceholder $property.Value
            }
        }
    }
}

Count-PromptPlaceholder $baseWorkflow

if ($placeholderCount -ne 1) {

    Write-Error @"
Workflow JSONの $PromptPlaceholder が正しく設定されていません。

現在の検出数: $placeholderCount

プロンプトを入れる場所を1か所だけ、

    "$PromptPlaceholder"

にしてください。
"@

    exit 1
}

Write-Host "Prompt placeholder: OK" -ForegroundColor Green

# =========================================================================
# GitHub Issue取得
# =========================================================================

Write-Section "GitHub Issue取得"

try {

    $issueJson = Invoke-GhJson @(
        "issue",
        "list",
        "--repo",
        $GithubRepo,
        "--state",
        "open",
        "--limit",
        "$IssueLimit",
        "--json",
        "number,title,body"
    )

    $issues = $issueJson | ConvertFrom-Json
}
catch {

    Write-Error "GitHub Issueの取得に失敗しました: $_"
    exit 1
}

$issues = @($issues)

if ($issues.Count -eq 0) {

    Write-Host "処理対象のOpen Issueはありません。" -ForegroundColor Green

    exit 0
}

Write-Host "$($issues.Count) 件のIssueを取得しました。" -ForegroundColor Cyan

# =========================================================================
# Issue処理
# =========================================================================

foreach ($issue in $issues) {

    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "Issue #$($issue.number): $($issue.title)" -ForegroundColor Magenta
    Write-Host "----------------------------------------" -ForegroundColor Gray

    # ---------------------------------------------------------------------
    # 二重処理防止
    # ---------------------------------------------------------------------

    if (Test-IssueAlreadyCompleted -IssueNumber ([int]$issue.number)) {

        Write-Host "このIssueには処理済みマーカーがあります。" -ForegroundColor Yellow
        Write-Host "二重処理を防止するためスキップします。" -ForegroundColor Yellow

        continue
    }

    $promptId = $null
    $videoFileName = $null

    try {

        # -----------------------------------------------------------------
        # Prompt
        # -----------------------------------------------------------------

        $promptText = $issue.body

        if ([string]::IsNullOrWhiteSpace($promptText)) {

            $promptText = $issue.title
        }

        $promptText = $promptText.Trim()

        Write-Host ""
        Write-Host "プロンプト:" -ForegroundColor DarkGray
        Write-Host $promptText -ForegroundColor White

        # -----------------------------------------------------------------
        # WorkflowをIssueごとに複製
        # -----------------------------------------------------------------

        $workflow = $workflowText | ConvertFrom-Json

        # -----------------------------------------------------------------
        # Prompt置換
        # -----------------------------------------------------------------

        $replacementCount = 0

        Replace-PromptPlaceholder `
            -Object $workflow `
            -PromptText $promptText `
            -ReplacementCount ([ref]$replacementCount)

        if ($replacementCount -ne 1) {

            throw "Prompt placeholderの置換に失敗しました。置換数: $replacementCount"
        }

        # -----------------------------------------------------------------
        # Seed自動ランダム化
        # -----------------------------------------------------------------

        $randomSeed = [Int64](
            Get-Random `
                -Minimum 1 `
                -Maximum 2147483647
        )

        Set-RandomSeed `
            -Workflow $workflow `
            -Seed $randomSeed

        Write-Host "Seed: $randomSeed" -ForegroundColor DarkGray

        # -----------------------------------------------------------------
        # ComfyUI Payload
        # -----------------------------------------------------------------

        $payloadObject = @{
            prompt = $workflow
        }

        $payload = $payloadObject |
            ConvertTo-Json `
                -Depth 100 `
                -Compress

        $payloadBytes = $Utf8NoBom.GetBytes($payload)

        # -----------------------------------------------------------------
        # ComfyUIへ送信
        # -----------------------------------------------------------------

        Write-Host ""
        Write-Host "ComfyUIへジョブ送信中..." -ForegroundColor Cyan

        try {

            $response = Invoke-RestMethod `
                -Uri $ComfyPromptUrl `
                -Method Post `
                -Body $payloadBytes `
                -ContentType "application/json; charset=utf-8" `
                -ErrorAction Stop
        }
        catch {

            throw "ComfyUIへの送信に失敗しました: $_"
        }

        if ($null -eq $response.prompt_id) {

            throw "ComfyUIからPrompt IDが返されませんでした。"
        }

        $promptId = [string]$response.prompt_id

        Write-Host "ジョブ送信成功！" -ForegroundColor Green
        Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow

        # -----------------------------------------------------------------
        # 完了待機
        # -----------------------------------------------------------------

        Write-Host ""
        Write-Host "最大60分、5分間隔で生成状態を確認します。" -ForegroundColor Cyan

        $startTime = Get-Date

        $videoOutput = $null

        while ($true) {

            $elapsedSeconds = (
                (Get-Date) - $startTime
            ).TotalSeconds

            $elapsedMinutes = [math]::Floor(
                $elapsedSeconds / 60
            )

            if ($elapsedSeconds -ge $MaxWaitSeconds) {

                throw "最大待機時間60分を超えました。"
            }

            Write-Host ""
            Write-Host "[$elapsedMinutes 分経過] ComfyUIを確認中..." -ForegroundColor Cyan

            $historyResponse = Get-ComfyHistory `
                -PromptId $promptId

            if ($null -ne $historyResponse) {

                if (
                    $historyResponse.PSObject.Properties.Name -contains $promptId
                ) {

                    $history = $historyResponse.$promptId

                    # status
                    if ($history.PSObject.Properties.Name -contains "status") {

                        $statusString = ""

                        if (
                            $history.status.PSObject.Properties.Name `
                            -contains "status_str"
                        ) {

                            $statusString = [string]$history.status.status_str
                        }

                        if ($statusString -match '(?i)error|failed') {

                            throw "ComfyUI側でジョブが失敗しました。status=$statusString"
                        }

                        if ($statusString) {

                            Write-Host "status: $statusString" -ForegroundColor DarkGray
                        }
                    }

                    # outputsから動画を探す
                    $videoOutput = Get-VideoOutputFromHistory `
                        -History $history

                    if ($null -ne $videoOutput) {

                        Write-Host "動画生成完了！" -ForegroundColor Green

                        break
                    }
                }
            }

            $remainingSeconds = `
                $MaxWaitSeconds - $elapsedSeconds

            $sleepSeconds = [int][math]::Min(
                $CheckIntervalSeconds,
                [math]::Max(1, $remainingSeconds)
            )

            Write-Host "まだ動画がありません。" -ForegroundColor DarkGray
            Write-Host "$([math]::Round($sleepSeconds / 60, 1))分後に再確認します。" -ForegroundColor DarkGray

            Start-Sleep -Seconds $sleepSeconds
        }

        # -----------------------------------------------------------------
        # 動画情報
        # -----------------------------------------------------------------

        $videoFileName = [System.IO.Path]::GetFileName(
            $videoOutput.Filename
        )

        $videoSubfolder = $videoOutput.Subfolder

        $videoType = $videoOutput.Type

        Write-Host ""
        Write-Host "動画:" -ForegroundColor Green
        Write-Host "  Filename : $videoFileName"
        Write-Host "  Subfolder: $videoSubfolder"
        Write-Host "  Type     : $videoType"
        Write-Host "  Node     : $($videoOutput.NodeId)"

        # -----------------------------------------------------------------
        # ComfyUIから直接コピー
        #
        # historyで得たfilename/subfolder/typeを使って
        # /viewから実データを取得します。
        # -----------------------------------------------------------------

        $viewParams = @{
            filename = $videoFileName
            subfolder = $videoSubfolder
            type = $videoType
        }

        $viewUrl = "$ComfyUrl/view"

        $targetCopyPath = Join-Path `
            $RepoVideoDir `
            $videoFileName

        Write-Host ""
        Write-Host "動画をComfyUIから取得しています..." -ForegroundColor Cyan

        try {

            Invoke-WebRequest `
                -Uri $viewUrl `
                -Method Get `
                -Body $null `
                -OutFile $targetCopyPath `
                -ErrorAction Stop
        }
        catch {

            # PowerShellのURIエンコード問題対策
            $query = @(
                "filename=$([System.Uri]::EscapeDataString($videoFileName))"
                "subfolder=$([System.Uri]::EscapeDataString($videoSubfolder))"
                "type=$([System.Uri]::EscapeDataString($videoType))"
            ) -join "&"

            $encodedViewUrl = "$viewUrl`?$query"

            Invoke-WebRequest `
                -Uri $encodedViewUrl `
                -Method Get `
                -OutFile $targetCopyPath `
                -ErrorAction Stop
        }

        if (!(Test-Path -LiteralPath $targetCopyPath)) {

            throw "動画の保存に失敗しました: $targetCopyPath"
        }

        $fileInfo = Get-Item -LiteralPath $targetCopyPath

        if ($fileInfo.Length -le 0) {

            throw "保存された動画ファイルのサイズが0バイトです。"
        }

        Write-Host "動画取得完了。" -ForegroundColor Green
        Write-Host "保存先: $targetCopyPath" -ForegroundColor Green
        Write-Host "サイズ: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor DarkGray

        # -----------------------------------------------------------------
        # index.html
        # -----------------------------------------------------------------

        if (!(Test-Path -LiteralPath $PagesFile)) {

            $initialHtml = @"
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">

    <title>MiniMax H3 動画生成ジョブ履歴</title>

    <style>
        body {
            font-family: sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: #f8f9fa;
            color: #333;
        }

        h1 {
            color: #212529;
            border-bottom: 3px solid #0d6efd;
            padding-bottom: 10px;
        }

        .job-card {
            background: white;
            padding: 20px;
            margin-bottom: 20px;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.05);
            border: 1px solid #dee2e6;
        }

        .date {
            color: #6c757d;
            font-size: 0.85em;
            margin-bottom: 10px;
        }

        .prompt {
            font-weight: bold;
            color: #0d6efd;
            margin: 10px 0;
            background: #e7f1ff;
            padding: 10px;
            border-radius: 5px;
            white-space: pre-wrap;
        }

        .id {
            font-family: monospace;
            background: #e9ecef;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.9em;
            word-break: break-all;
        }

        video {
            width: 100%;
            border-radius: 6px;
            margin-top: 15px;
            background: #000;
        }

        .video-name {
            color: #6c757d;
            font-size: 0.85em;
            margin-top: 8px;
        }
    </style>
</head>

<body>

    <h1>🎬 MiniMax H3 動画生成ジョブ履歴</h1>

    <!-- JOBS_START -->
    <!-- JOBS_END -->

</body>
</html>
"@

            [System.IO.File]::WriteAllText(
                $PagesFile,
                $initialHtml,
                $Utf8NoBom
            )
        }

        # -----------------------------------------------------------------
        # HTML用データ
        # -----------------------------------------------------------------

        $safePrompt = ConvertTo-HtmlSafe $promptText
        $safePromptId = ConvertTo-HtmlSafe $promptId
        $safeVideoName = ConvertTo-HtmlSafe $videoFileName

        $currentDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $videoUrlName = [System.Uri]::EscapeDataString(
            $videoFileName
        )

        $newJobHtml = @"
    <div class="job-card">

        <div class="date">
            処理日時: $currentDate (Issue #$($issue.number))
        </div>

        <div class="prompt">
            プロンプト: $safePrompt
        </div>

        <div>
            Prompt ID:
            <span class="id">$safePromptId</span>
        </div>

        <video controls preload="metadata"
               src="videos/$videoUrlName"></video>

        <div class="video-name">
            $safeVideoName
        </div>

    </div>
"@

        $htmlContent = [System.IO.File]::ReadAllText(
            $PagesFile,
            $Utf8NoBom
        )

        if ($htmlContent -notmatch "<!-- JOBS_START -->") {

            throw "index.htmlにJOB​​S_STARTがありません。"
        }

        $htmlContent = $htmlContent.Replace(
            "<!-- JOBS_START -->",
            "<!-- JOBS_START -->`r`n$newJobHtml"
        )

        [System.IO.File]::WriteAllText(
            $PagesFile,
            $htmlContent,
            $Utf8NoBom
        )

        Write-Host "index.html更新完了。" -ForegroundColor Green

        # -----------------------------------------------------------------
        # Git
        # -----------------------------------------------------------------

        Write-Host ""
        Write-Host "Gitへ成果物を登録します..." -ForegroundColor Cyan

        git add -- docs/

        if ($LASTEXITCODE -ne 0) {

            throw "git addに失敗しました。"
        }

        # docs以外の事前staged変更がある場合は事故防止
        $stagedFiles = @(git diff --cached --name-only)

        $outsideDocs = @(
            $stagedFiles |
            Where-Object {
                $_ -and ($_ -notmatch '^docs/')
            }
        )

        if ($outsideDocs.Count -gt 0) {

            throw @"
docs/以外の変更が既にstagedされています。

安全のためcommitを中止しました。

$($outsideDocs -join "`n")
"@
        }

        git diff --cached --quiet

        if ($LASTEXITCODE -eq 0) {

            throw "docs/にcommit対象の変更がありません。"
        }

        git commit `
            -m "Auto-update Pages [skip ci]"

        if ($LASTEXITCODE -ne 0) {

            throw "git commitに失敗しました。"
        }

        git push origin main

        if ($LASTEXITCODE -ne 0) {

            throw "git pushに失敗しました。"
        }

        Write-Host "GitHubへのpush完了。" -ForegroundColor Green

        # -----------------------------------------------------------------
        # 成功マーカーをIssueへ追加
        #
        # ここまで来たら「動画生成 + Pages + Git push」が全部成功。
        # -----------------------------------------------------------------

        Add-SuccessComment `
            -IssueNumber ([int]$issue.number) `
            -PromptId $promptId `
            -VideoFileName $videoFileName

        Write-Host "成功マーカーをIssueに追加しました。" -ForegroundColor Green

        # -----------------------------------------------------------------
        # Issue Close
        # -----------------------------------------------------------------

        Close-Issue `
            -IssueNumber ([int]$issue.number) `
            -PromptId $promptId `
            -VideoFileName $videoFileName

        Write-Host ""
        Write-Host "Issue #$($issue.number) 完了！" -ForegroundColor Green
        Write-Host "Prompt ID: $promptId" -ForegroundColor Green
        Write-Host "Video: $videoFileName" -ForegroundColor Green
    }
    catch {

        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "Issue #$($issue.number) の処理に失敗しました。" -ForegroundColor Red
        Write-Host $_ -ForegroundColor Red
        Write-Host "このIssueはクローズしません。" -ForegroundColor Yellow
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

        continue
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "すべてのIssue処理が終了しました。" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
