# =========================================================================
# GitHub Issue → ComfyUI → Video → GitHub Pages
# 常駐自動処理版
#
# 動作:
#
#   1. GitHubのOpen Issueを5分ごとに確認
#   2. Issue本文をComfyUIプロンプトとして使用
#   3. Workflow JSON内の __TARGET_PROMPT__ を置換
#   4. RandomNoiseのSeedを毎回ランダム化
#   5. ComfyUIへジョブ送信
#   6. Prompt IDをIssueへ即座に記録
#   7. 最大60分、5分間隔で生成完了を確認
#   8. 動画をdocs/videosへコピー
#   9. docs/index.html更新
#  10. Git commit / push
#  11. 成功したらIssueをClose
#  12. 5分待機して次のIssue確認
#
# Ctrl+C で終了
#
# =========================================================================

param(
    [string]$WorkflowJson = ".\workflows\video_minimax_h3_t2v.json",

    # GitHub確認間隔
    [int]$LoopIntervalSeconds = 300
)

# =========================================================================
# 設定
# =========================================================================

$GithubRepo = "mochi-contents-lab/makemovie"

$ComfyUrl = "http://127.0.0.1:8188"

$ComfyPromptUrl  = "$ComfyUrl/prompt"
$ComfyHistoryUrl = "$ComfyUrl/history"
$ComfySystemUrl  = "$ComfyUrl/system_stats"

# ComfyUIの実際の動画出力先
$ComfyOutputDir = "F:\aiimg\StabilityMatrix\Data\Images\Text2Img\video"

# GitHub Pages
$RepoVideoDir = "docs\videos"
$PagesFile = "docs\index.html"

# 1回のGitHub確認で取得するIssue数
$IssueLimit = 10

# ComfyUI生成確認間隔
$CheckIntervalSeconds = 300

# ComfyUI生成最大待機時間
$MaxWaitSeconds = 3600

# Workflow JSONのプロンプト置換文字列
$PromptPlaceholder = "__TARGET_PROMPT__"

# Issueコメントマーカー
$SuccessMarker = "[COMFYUI-AUTO-COMPLETED]"
$JobMarker = "[COMFYUI-AUTO-JOB]"

# =========================================================================
# UTF-8
# =========================================================================

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
}
catch {}

$OutputEncoding = $Utf8NoBom

# =========================================================================
# 表示
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
# GitHub CLI JSON
# =========================================================================

function Invoke-GhJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = "gh"

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
        $psi.StandardOutputEncoding = $Utf8NoBom
        $psi.StandardErrorEncoding = $Utf8NoBom
    }
    catch {}

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
# Issueコメント取得
# =========================================================================

function Get-IssueComments {
    param(
        [int]$IssueNumber
    )

    $json = Invoke-GhJson @(
        "issue",
        "view",
        "$IssueNumber",
        "--repo",
        $GithubRepo,
        "--json",
        "comments"
    )

    return ($json | ConvertFrom-Json).comments
}

# =========================================================================
# 既存ジョブ情報取得
# =========================================================================

function Get-ExistingJobInfo {
    param(
        [int]$IssueNumber
    )

    $comments = Get-IssueComments `
        -IssueNumber $IssueNumber

    $result = [PSCustomObject]@{
        Completed = $false
        PromptId = $null
        VideoFileName = $null
        Seed = $null
    }

    foreach ($comment in @($comments)) {

        $body = [string]$comment.body

        # -------------------------------------------------------------
        # 完了済み
        #
        # -like は [] をワイルドカードとして扱うため使用しない。
        # -------------------------------------------------------------

        if ($body.Contains($SuccessMarker)) {

            $result.Completed = $true
        }

        # -------------------------------------------------------------
        # ジョブ情報
        # -------------------------------------------------------------

        if ($body.Contains($JobMarker)) {

            $match = [regex]::Match(
                $body,
                'Prompt ID:\s*([^\s]+)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $result.PromptId = $match.Groups[1].Value
            }

            $match = [regex]::Match(
                $body,
                'Video:\s*(\S+)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $result.VideoFileName = $match.Groups[1].Value
            }

            $match = [regex]::Match(
                $body,
                'Seed:\s*(\d+)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $result.Seed = $match.Groups[1].Value
            }
        }
    }

    return $result
}

# =========================================================================
# Issueへジョブ情報を記録
# =========================================================================

function Add-JobComment {
    param(
        [int]$IssueNumber,

        [string]$PromptId,

        [Int64]$Seed
    )

    $comment = @"
$JobMarker

ComfyUIジョブを送信しました。

Prompt ID: $PromptId
Seed: $Seed

このジョブは処理中です。
次回実行時にはPrompt IDを使用して再送信を防止します。
"@

    $result = & gh issue comment `
        $IssueNumber `
        --repo $GithubRepo `
        --body $comment 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "Issueへのジョブ情報記録に失敗しました: $result"
    }
}

# =========================================================================
# 完了コメント
# =========================================================================

function Add-CompletedComment {
    param(
        [int]$IssueNumber,

        [string]$PromptId,

        [string]$VideoFileName
    )

    $comment = @"
$SuccessMarker

ComfyUI動画生成が正常に完了しました。

Prompt ID: $PromptId
Video: $VideoFileName

GitHub Pagesへの反映も完了しています。
"@

    $result = & gh issue comment `
        $IssueNumber `
        --repo $GithubRepo `
        --body $comment 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "Issueへの完了コメント投稿に失敗しました: $result"
    }
}

# =========================================================================
# Issue Close
# =========================================================================

function Close-Issue {
    param(
        [int]$IssueNumber,

        [string]$PromptId,

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
# Prompt置換
# =========================================================================

function Replace-PromptPlaceholder {
    param(
        $Object,

        [string]$PromptText,

        [ref]$ReplacementCount
    )

    if ($null -eq $Object) {
        return
    }

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
# RandomNoise Seed設定
# =========================================================================

function Set-RandomSeed {
    param(
        $Workflow,

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

                if (
                    $node.inputs.PSObject.Properties.Name `
                    -contains "noise_seed"
                ) {

                    $node.inputs.noise_seed = $Seed

                    $found = $true

                    Write-Host `
                        "RandomNoise Seed: $Seed" `
                        -ForegroundColor DarkGray
                }
            }
        }
    }

    if (!$found) {

        throw "Workflow JSON内にRandomNoiseノードが見つかりません。"
    }
}

# =========================================================================
# ComfyUI History取得
# =========================================================================

function Get-ComfyHistory {
    param(
        [string]$PromptId
    )

    try {

        return Invoke-RestMethod `
            -Uri "$ComfyHistoryUrl/$PromptId" `
            -Method Get `
            -ErrorAction Stop
    }
    catch {

        return $null
    }
}

# =========================================================================
# Historyから動画を探す
# =========================================================================

function Get-VideoOutputFromHistory {
    param(
        $History
    )

    if ($null -eq $History) {
        return $null
    }

    if (
        $History.PSObject.Properties.Name `
        -notcontains "outputs"
    ) {
        return $null
    }

    foreach ($nodeProperty in $History.outputs.PSObject.Properties) {

        $nodeOutput = $nodeProperty.Value

        if ($null -eq $nodeOutput) {
            continue
        }

        foreach ($outputName in @("videos", "images")) {

            if (
                $nodeOutput.PSObject.Properties.Name `
                -contains $outputName
            ) {

                foreach ($item in @($nodeOutput.$outputName)) {

                    if ($null -eq $item.filename) {
                        continue
                    }

                    $extension = [System.IO.Path]::GetExtension(
                        [string]$item.filename
                    )

                    if (
                        $extension -match
                        '(?i)^\.(mp4|webm|mov|mkv|avi)$'
                    ) {

                        return [PSCustomObject]@{
                            Filename = [string]$item.filename
                            Subfolder = [string]$item.subfolder
                            Type = [string]$item.type
                            NodeId = [string]$nodeProperty.Name
                        }
                    }
                }
            }
        }
    }

    return $null
}

# =========================================================================
# ローカル動画検索
# =========================================================================

function Find-LocalVideo {
    param(
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {

        return $null
    }

    # まず直下を確認
    $directPath = Join-Path `
        $ComfyOutputDir `
        $FileName

    if (Test-Path -LiteralPath $directPath) {

        return Get-Item -LiteralPath $directPath
    }

    # サブフォルダも検索
    $found = Get-ChildItem `
        -Path $ComfyOutputDir `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $FileName
        } |
        Select-Object -First 1

    return $found
}

# =========================================================================
# 動画コピー
# =========================================================================

function Copy-ComfyVideo {
    param(
        $VideoOutput,

        [string]$KnownFileName
    )

    $fileName = $null

    if ($null -ne $VideoOutput) {

        $fileName = [System.IO.Path]::GetFileName(
            $VideoOutput.Filename
        )
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {

        $fileName = $KnownFileName
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {

        throw "動画ファイル名を特定できません。"
    }

    $localVideo = Find-LocalVideo `
        -FileName $fileName

    if ($null -eq $localVideo) {

        throw `
            "ComfyUI出力フォルダに動画が見つかりません: $fileName"
    }

    if (!(Test-Path -LiteralPath $RepoVideoDir)) {

        New-Item `
            -ItemType Directory `
            -Path $RepoVideoDir `
            -Force |
            Out-Null
    }

    $target = Join-Path `
        $RepoVideoDir `
        $fileName

    Copy-Item `
        -LiteralPath $localVideo.FullName `
        -Destination $target `
        -Force

    $targetInfo = Get-Item `
        -LiteralPath $target

    if ($targetInfo.Length -le 0) {

        throw "コピーされた動画が0バイトです。"
    }

    Write-Host ""
    Write-Host "動画コピー完了:" -ForegroundColor Green
    Write-Host $target -ForegroundColor Green

    return $fileName
}

# =========================================================================
# GitHub Pages更新
# =========================================================================

function Update-Pages {
    param(
        [int]$IssueNumber,

        [string]$PromptText,

        [string]$PromptId,

        [string]$VideoFileName
    )

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

    # -------------------------------------------------------------
    # index.html初回作成
    # -------------------------------------------------------------

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

    # -------------------------------------------------------------
    # index.html読み込み
    # -------------------------------------------------------------

    $html = [System.IO.File]::ReadAllText(
        $PagesFile,
        $Utf8NoBom
    )

    if ($html -notmatch "<!-- JOBS_START -->") {

        throw "index.htmlにJOBS_STARTがありません。"
    }

    # -------------------------------------------------------------
    # HTMLエスケープ
    # -------------------------------------------------------------

    $safePrompt = [System.Net.WebUtility]::HtmlEncode(
        $PromptText
    )

    $safePromptId = [System.Net.WebUtility]::HtmlEncode(
        $PromptId
    )

    $safeVideoName = [System.Net.WebUtility]::HtmlEncode(
        $VideoFileName
    )

    $videoUrl = [System.Uri]::EscapeDataString(
        $VideoFileName
    )

    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # -------------------------------------------------------------
    # 新しいジョブ
    # -------------------------------------------------------------

    $newJob = @"
<div class="job-card">

<div class="date">
処理日時: $date (Issue #$IssueNumber)
</div>

<div class="prompt">
プロンプト: $safePrompt
</div>

<div>
Prompt ID:
<span class="id">$safePromptId</span>
</div>

<video controls preload="metadata"
src="videos/$videoUrl"></video>

<div>
$safeVideoName
</div>

</div>
"@

    # -------------------------------------------------------------
    # JOBS_START直後へ追加
    # -------------------------------------------------------------

    $html = $html.Replace(
        "<!-- JOBS_START -->",
        "<!-- JOBS_START -->`r`n$newJob"
    )

    [System.IO.File]::WriteAllText(
        $PagesFile,
        $html,
        $Utf8NoBom
    )

    Write-Host `
        "GitHub Pagesのindex.htmlを更新しました。" `
        -ForegroundColor Green
}

# =========================================================================
# Git commit / push
# =========================================================================

function Publish-Docs {

    Write-Host ""
    Write-Host `
        "GitHub Pagesへ成果物をプッシュします..." `
        -ForegroundColor Cyan

    # -------------------------------------------------------------
    # docs追加
    # -------------------------------------------------------------

    git add -- docs/

    if ($LASTEXITCODE -ne 0) {

        throw "git addに失敗しました。"
    }

    # -------------------------------------------------------------
    # 変更確認
    # -------------------------------------------------------------

    git diff --cached --quiet

    if ($LASTEXITCODE -eq 0) {

        Write-Host `
            "docs/に新しい変更はありません。" `
            -ForegroundColor Yellow

        return
    }

    # -------------------------------------------------------------
    # Commit
    # -------------------------------------------------------------

    git commit `
        -m "Auto-update Pages [skip ci]"

    if ($LASTEXITCODE -ne 0) {

        throw "git commitに失敗しました。"
    }

    # -------------------------------------------------------------
    # Push
    # -------------------------------------------------------------

    git push origin main

    if ($LASTEXITCODE -ne 0) {

        throw "git pushに失敗しました。"
    }

    Write-Host `
        "GitHubへのpush完了。" `
        -ForegroundColor Green
}

# =========================================================================
# Workflow読み込み
# =========================================================================

function Load-Workflow {

    if (!(Test-Path -LiteralPath $WorkflowJson)) {

        throw "Workflow JSONがありません: $WorkflowJson"
    }

    $workflowText = [System.IO.File]::ReadAllText(
        (Resolve-Path $WorkflowJson),
        $Utf8NoBom
    )

    $workflow = $workflowText | ConvertFrom-Json

    return [PSCustomObject]@{
        Text = $workflowText
        Object = $workflow
    }
}

# =========================================================================
# Workflow placeholder確認
# =========================================================================

function Test-WorkflowPlaceholder {
    param(
        $Workflow
    )

    $script:placeholderCount = 0

    function Count-Placeholder {
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

                    Count-Placeholder $item
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

                    Count-Placeholder $property.Value
                }
            }
        }
    }

    Count-Placeholder $Workflow

    $count = $script:placeholderCount

    $script:placeholderCount = 0

    if ($count -ne 1) {

        throw `
            "Workflow JSON内の $PromptPlaceholder が1個ではありません。現在: $count"
    }

    Write-Host `
        "Workflow placeholder OK" `
        -ForegroundColor Green
}

# =========================================================================
# Issueを1件処理
# =========================================================================

function Process-Issue {
    param(
        $Issue,

        $BaseWorkflow
    )

    $issueNumber = [int]$Issue.number

    Write-Host ""
    Write-Host `
        "----------------------------------------" `
        -ForegroundColor Gray

    Write-Host `
        "Processing Issue #$issueNumber : $($Issue.title)" `
        -ForegroundColor Magenta

    Write-Host `
        "----------------------------------------" `
        -ForegroundColor Gray

    # -------------------------------------------------------------
    # 既存ジョブ確認
    # -------------------------------------------------------------

    $existingJob = Get-ExistingJobInfo `
        -IssueNumber $issueNumber

    # -------------------------------------------------------------
    # 完了済み
    # -------------------------------------------------------------

    if ($existingJob.Completed) {

        Write-Host `
            "このIssueは既に処理完了しています。" `
            -ForegroundColor Green

        Write-Host `
            "二重処理防止のためスキップします。" `
            -ForegroundColor Yellow

        return
    }

    # -------------------------------------------------------------
    # Prompt
    # -------------------------------------------------------------

    $promptText = [string]$Issue.body

    if ([string]::IsNullOrWhiteSpace($promptText)) {

        $promptText = [string]$Issue.title
    }

    $promptText = $promptText.Trim()

    Write-Host ""
    Write-Host `
        "抽出されたプロンプト:" `
        -ForegroundColor DarkGray

    Write-Host `
        $promptText `
        -ForegroundColor White

    $promptId = $existingJob.PromptId
    $videoFileName = $existingJob.VideoFileName

    # -------------------------------------------------------------
    # 新規ジョブ
    # -------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($promptId)) {

        Write-Host ""
        Write-Host `
            "新規ComfyUIジョブを作成します。" `
            -ForegroundColor Cyan

        # ---------------------------------------------------------
        # Workflowコピー
        # ---------------------------------------------------------

        $workflow = $BaseWorkflow.Text | ConvertFrom-Json

        # ---------------------------------------------------------
        # Prompt置換
        # ---------------------------------------------------------

        $replacementCount = 0

        Replace-PromptPlaceholder `
            -Object $workflow `
            -PromptText $promptText `
            -ReplacementCount ([ref]$replacementCount)

        if ($replacementCount -ne 1) {

            throw `
                "Prompt placeholderの置換に失敗しました。"
        }

        # ---------------------------------------------------------
        # Random Seed
        # ---------------------------------------------------------

        $seed = [Int64](
            Get-Random `
                -Minimum 1 `
                -Maximum 2147483647
        )

        Set-RandomSeed `
            -Workflow $workflow `
            -Seed $seed

        # ---------------------------------------------------------
        # Payload
        # ---------------------------------------------------------

        $payloadObject = @{
            prompt = $workflow
        }

        $payload = $payloadObject |
            ConvertTo-Json `
                -Depth 100 `
                -Compress

        $payloadBytes = $Utf8NoBom.GetBytes(
            $payload
        )

        # ---------------------------------------------------------
        # ComfyUI送信
        # ---------------------------------------------------------

        Write-Host ""
        Write-Host `
            "ComfyUI ジョブを送信中..." `
            -ForegroundColor Cyan

        $response = Invoke-RestMethod `
            -Uri $ComfyPromptUrl `
            -Method Post `
            -Body $payloadBytes `
            -ContentType "application/json; charset=utf-8" `
            -ErrorAction Stop

        if ($null -eq $response.prompt_id) {

            throw `
                "ComfyUIからPrompt IDが返されませんでした。"
        }

        $promptId = [string]$response.prompt_id

        Write-Host `
            "ジョブ送信成功！" `
            -ForegroundColor Green

        Write-Host `
            "Prompt ID: $promptId" `
            -ForegroundColor Yellow

        # ---------------------------------------------------------
        # ★重要
        #
        # Prompt IDを即座にIssueへ保存
        #
        # この後Git等が失敗しても、
        # 次回ループでは再送信しない。
        # ---------------------------------------------------------

        Add-JobComment `
            -IssueNumber $issueNumber `
            -PromptId $promptId `
            -Seed $seed

        Write-Host `
            "Prompt IDをIssueへ記録しました。" `
            -ForegroundColor Green
    }
    else {

        Write-Host ""
        Write-Host `
            "既存のComfyUIジョブを検出しました。" `
            -ForegroundColor Yellow

        Write-Host `
            "Prompt ID: $promptId" `
            -ForegroundColor Yellow

        Write-Host `
            "ComfyUIへの再送信は行いません。" `
            -ForegroundColor Green
    }

    # -------------------------------------------------------------
    # 動画生成待機
    # -------------------------------------------------------------

    Write-Host ""
    Write-Host `
        "動画生成を最大60分待機します。" `
        -ForegroundColor Cyan

    Write-Host `
        "5分ごとにComfyUIを確認します。" `
        -ForegroundColor DarkGray

    $startTime = Get-Date

    $videoOutput = $null

    while ($true) {

        $elapsed = (
            (Get-Date) - $startTime
        ).TotalSeconds

        $minutes = [math]::Floor(
            $elapsed / 60
        )

        Write-Host ""

        Write-Host `
            "[$minutes 分経過] ComfyUIの生成状態を確認中..." `
            -ForegroundColor Cyan

        $historyResponse = Get-ComfyHistory `
            -PromptId $promptId

        if ($null -ne $historyResponse) {

            if (
                $historyResponse.PSObject.Properties.Name `
                -contains $promptId
            ) {

                $history = $historyResponse.$promptId

                # -------------------------------------------------
                # エラー確認
                # -------------------------------------------------

                if (
                    $history.PSObject.Properties.Name `
                    -contains "status"
                ) {

                    if (
                        $history.status.PSObject.Properties.Name `
                        -contains "status_str"
                    ) {

                        $status = [string]$history.status.status_str

                        Write-Host `
                            "Status: $status" `
                            -ForegroundColor DarkGray

                        if (
                            $status -match `
                            '(?i)error|failed'
                        ) {

                            throw `
                                "ComfyUIジョブが失敗しました。Status=$status"
                        }
                    }
                }

                # -------------------------------------------------
                # 動画確認
                # -------------------------------------------------

                $videoOutput = Get-VideoOutputFromHistory `
                    -History $history

                if ($null -ne $videoOutput) {

                    Write-Host ""
                    Write-Host `
                        "動画生成完了！" `
                        -ForegroundColor Green

                    break
                }
            }
        }

        # -------------------------------------------------------------
        # タイムアウト
        # -------------------------------------------------------------

        if ($elapsed -ge $MaxWaitSeconds) {

            throw `
                "最大待機時間60分を超えました。"
        }

        Write-Host `
            "まだ生成中です。5分後に再確認します。" `
            -ForegroundColor DarkGray

        Start-Sleep `
            -Seconds $CheckIntervalSeconds
    }

    # -------------------------------------------------------------
    # 動画ファイル名
    # -------------------------------------------------------------

    if ($null -ne $videoOutput) {

        $videoFileName = [System.IO.Path]::GetFileName(
            $videoOutput.Filename
        )

        Write-Host ""
        Write-Host `
            "生成された動画:" `
            -ForegroundColor Green

        Write-Host `
            "  Filename : $videoFileName"

        Write-Host `
            "  Subfolder: $($videoOutput.Subfolder)"

        Write-Host `
            "  Type     : $($videoOutput.Type)"
    }

    # -------------------------------------------------------------
    # 動画コピー
    # -------------------------------------------------------------

    $videoFileName = Copy-ComfyVideo `
        -VideoOutput $videoOutput `
        -KnownFileName $videoFileName

    # -------------------------------------------------------------
    # GitHub Pages更新
    # -------------------------------------------------------------

    Update-Pages `
        -IssueNumber $issueNumber `
        -PromptText $promptText `
        -PromptId $promptId `
        -VideoFileName $videoFileName

    # -------------------------------------------------------------
    # Git commit / push
    # -------------------------------------------------------------

    Publish-Docs

    # -------------------------------------------------------------
    # 完了コメント
    # -------------------------------------------------------------

    Add-CompletedComment `
        -IssueNumber $issueNumber `
        -PromptId $promptId `
        -VideoFileName $videoFileName

    # -------------------------------------------------------------
    # Issue Close
    # -------------------------------------------------------------

    Close-Issue `
        -IssueNumber $issueNumber `
        -PromptId $promptId `
        -VideoFileName $videoFileName

    Write-Host ""
    Write-Host `
        "Issue #$issueNumber 完了！" `
        -ForegroundColor Green

    Write-Host `
        "Prompt ID: $promptId" `
        -ForegroundColor Green

    Write-Host `
        "Video: $videoFileName" `
        -ForegroundColor Green
}

# =========================================================================
# 起動
# =========================================================================

Write-Section `
    "GitHub Issue → ComfyUI → Video → GitHub Pages 常駐自動処理"

Write-Host ""
Write-Host `
    "Workflow : $WorkflowJson" `
    -ForegroundColor DarkGray

Write-Host `
    "Issue確認: $LoopIntervalSeconds 秒ごと" `
    -ForegroundColor DarkGray

Write-Host `
    "生成待機 : 最大60分" `
    -ForegroundColor DarkGray

Write-Host ""
Write-Host `
    "Ctrl+C で終了します。" `
    -ForegroundColor Yellow

# =========================================================================
# 初期チェック
# =========================================================================

Write-Host ""
Write-Host `
    "初期チェック中..." `
    -ForegroundColor Cyan

# -------------------------------------------------------------
# Workflow
# -------------------------------------------------------------

if (!(Test-Path -LiteralPath $WorkflowJson)) {

    Write-Error `
        "Workflow JSONがありません: $WorkflowJson"

    exit 1
}

# -------------------------------------------------------------
# ComfyUI出力
# -------------------------------------------------------------

if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

    Write-Error `
        "ComfyUI出力フォルダがありません:"

    Write-Error `
        $ComfyOutputDir

    exit 1
}

# -------------------------------------------------------------
# ComfyUI接続
# -------------------------------------------------------------

try {

    Invoke-RestMethod `
        -Uri $ComfySystemUrl `
        -Method Get `
        -ErrorAction Stop |
        Out-Null

    Write-Host `
        "ComfyUI 接続OK" `
        -ForegroundColor Green
}
catch {

    Write-Error `
        "ComfyUIに接続できません: $ComfyUrl"

    exit 1
}

# -------------------------------------------------------------
# Workflow読み込み
# -------------------------------------------------------------

try {

    $BaseWorkflow = Load-Workflow

    Test-WorkflowPlaceholder `
        -Workflow $BaseWorkflow.Object
}
catch {

    Write-Error $_

    exit 1
}

# -------------------------------------------------------------
# Git確認
# -------------------------------------------------------------

try {

    $gitName = git config user.name
    $gitEmail = git config user.email

    if (
        [string]::IsNullOrWhiteSpace($gitName) -or
        [string]::IsNullOrWhiteSpace($gitEmail)
    ) {

        throw `
            "Git user.name / user.email が設定されていません。"
    }

    Write-Host `
        "Git user: $gitName <$gitEmail>" `
        -ForegroundColor DarkGray
}
catch {

    Write-Error $_

    exit 1
}

# -------------------------------------------------------------
# GitHub CLI確認
# -------------------------------------------------------------

try {

    $null = & gh auth status 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "GitHub CLIの認証状態を確認できません。"
    }

    Write-Host `
        "GitHub CLI 接続OK" `
        -ForegroundColor Green
}
catch {

    Write-Error $_

    exit 1
}

Write-Host ""
Write-Host `
    "初期チェック完了。" `
    -ForegroundColor Green

# =========================================================================
# 常駐ループ
# =========================================================================

while ($true) {

    try {

        Write-Section `
            "GitHub Issue確認"

        Write-Host `
            "Open Issueを確認しています..." `
            -ForegroundColor Cyan

        # -------------------------------------------------------------
        # Issue取得
        # -------------------------------------------------------------

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

        $issues = @(
            $issueJson | ConvertFrom-Json
        )

        # -------------------------------------------------------------
        # Issueなし
        # -------------------------------------------------------------

        if ($issues.Count -eq 0) {

            Write-Host ""
            Write-Host `
                "処理対象のOpen Issueはありません。" `
                -ForegroundColor Green

            Write-Host ""
            Write-Host `
                "次回確認まで $LoopIntervalSeconds 秒待機します。" `
                -ForegroundColor DarkGray

            Start-Sleep `
                -Seconds $LoopIntervalSeconds

            continue
        }

        # -------------------------------------------------------------
        # Issueあり
        # -------------------------------------------------------------

        Write-Host ""
        Write-Host `
            "$($issues.Count) 件のOpen Issueを検出しました。" `
            -ForegroundColor Cyan

        # -------------------------------------------------------------
        # Issueを順番に処理
        # -------------------------------------------------------------

        foreach ($issue in $issues) {

            try {

                Process-Issue `
                    -Issue $issue `
                    -BaseWorkflow $BaseWorkflow
            }
            catch {

                Write-Host ""
                Write-Host `
                    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" `
                    -ForegroundColor Red

                Write-Host `
                    "Issue #$($issue.number) の処理に失敗しました。" `
                    -ForegroundColor Red

                Write-Host ""
                Write-Host `
                    $_ `
                    -ForegroundColor Red

                Write-Host ""
                Write-Host `
                    "Issueはクローズしません。" `
                    -ForegroundColor Yellow

                Write-Host `
                    "次回ループで再確認します。" `
                    -ForegroundColor Yellow

                Write-Host `
                    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" `
                    -ForegroundColor Red

                # -----------------------------------------------------
                # 1件失敗しても次のIssueへ進む
                # -----------------------------------------------------

                continue
            }
        }

        # -------------------------------------------------------------
        # 今回のチェック終了
        # -------------------------------------------------------------

        Write-Host ""
        Write-Host `
            "今回のIssueチェックが終了しました。" `
            -ForegroundColor Green

        Write-Host ""
        Write-Host `
            "次回GitHub確認まで $LoopIntervalSeconds 秒待機します。" `
            -ForegroundColor DarkGray

        Start-Sleep `
            -Seconds $LoopIntervalSeconds
    }
    catch {

        # =============================================================
        # GitHub / ネットワーク等のメインループエラー
        # =============================================================

        Write-Host ""
        Write-Host `
            "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" `
            -ForegroundColor Red

        Write-Host `
            "メインループでエラーが発生しました。" `
            -ForegroundColor Red

        Write-Host ""
        Write-Host `
            $_ `
            -ForegroundColor Red

        Write-Host ""
        Write-Host `
            "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" `
            -ForegroundColor Red

        Write-Host ""
        Write-Host `
            "$LoopIntervalSeconds 秒後に再試行します。" `
            -ForegroundColor Yellow

        Start-Sleep `
            -Seconds $LoopIntervalSeconds
    }
}
