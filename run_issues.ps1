# =========================================================================
# GitHub Issue → ComfyUI → Video → GitHub Pages 自動処理
#
# Workflow:
#
#   workflows\minimax_h3.json
#
# Workflow JSONではプロンプト部分だけ、
#
#   "__TARGET_PROMPT__"
#
# としてください。
#
# Seedは通常の数値でOK。
# RandomNoiseノードのnoise_seedを自動ランダム化します。
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

$IssueLimit = 10

# 5分間隔
$CheckIntervalSeconds = 300

# 最大60分
$MaxWaitSeconds = 3600

$PromptPlaceholder = "__TARGET_PROMPT__"

# 成功済みマーカー
$SuccessMarker = "[COMFYUI-AUTO-COMPLETED]"

# ジョブ登録マーカー
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
# 既存ジョブ情報をコメントから取得
# =========================================================================

function Get-ExistingJobInfo {
    param(
        [int]$IssueNumber
    )

    $comments = Get-IssueComments -IssueNumber $IssueNumber

    $result = [PSCustomObject]@{
        Completed = $false
        PromptId = $null
        VideoFileName = $null
        Seed = $null
    }

    foreach ($comment in @($comments)) {

        $body = [string]$comment.body

        if ($body -like "*$SuccessMarker*") {

            $result.Completed = $true
        }

        if ($body -like "*$JobMarker*") {

            $match = [regex]::Match(
                $body,
                'Prompt ID:\s*([a-f0-9\-]+)',
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
# Seed変更
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

                if ($node.inputs.PSObject.Properties.Name -contains "noise_seed") {

                    $node.inputs.noise_seed = $Seed

                    $found = $true

                    Write-Host "RandomNoise Seed: $Seed" -ForegroundColor DarkGray
                }
            }
        }
    }

    if (!$found) {

        throw "RandomNoiseノードが見つかりません。"
    }
}

# =========================================================================
# ComfyUI History
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

    if ($History.PSObject.Properties.Name -notcontains "outputs") {
        return $null
    }

    foreach ($nodeProperty in $History.outputs.PSObject.Properties) {

        $nodeOutput = $nodeProperty.Value

        if ($null -eq $nodeOutput) {
            continue
        }

        foreach ($outputName in @("videos", "images")) {

            if ($nodeOutput.PSObject.Properties.Name -contains $outputName) {

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
# 動画をローカルから探す
# =========================================================================

function Find-LocalVideo {
    param(
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return $null
    }

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

    if ($VideoOutput -ne $null) {

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

        throw "ComfyUI出力フォルダに動画が見つかりません: $fileName"
    }

    $target = Join-Path `
        $RepoVideoDir `
        $fileName

    Copy-Item `
        -LiteralPath $localVideo.FullName `
        -Destination $target `
        -Force

    $targetInfo = Get-Item -LiteralPath $target

    if ($targetInfo.Length -le 0) {

        throw "コピーされた動画が0バイトです。"
    }

    Write-Host "動画コピー完了:" -ForegroundColor Green
    Write-Host $target -ForegroundColor Green

    return $fileName
}

# =========================================================================
# index.html作成・更新
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

    $html = [System.IO.File]::ReadAllText(
        $PagesFile,
        $Utf8NoBom
    )

    if ($html -notmatch "<!-- JOBS_START -->") {

        throw "index.htmlにJOBS_STARTがありません。"
    }

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

    $html = $html.Replace(
        "<!-- JOBS_START -->",
        "<!-- JOBS_START -->`r`n$newJob"
    )

    [System.IO.File]::WriteAllText(
        $PagesFile,
        $html,
        $Utf8NoBom
    )

    Write-Host "GitHub Pages更新完了。" -ForegroundColor Green
}

# =========================================================================
# Git commit / push
# =========================================================================

function Publish-Docs {

    Write-Host ""
    Write-Host "GitHub Pagesへ成果物をプッシュします..." -ForegroundColor Cyan

    git add -- docs/

    if ($LASTEXITCODE -ne 0) {

        throw "git addに失敗しました。"
    }

    git diff --cached --quiet

    if ($LASTEXITCODE -eq 0) {

        Write-Host "docs/に新しい変更はありません。" -ForegroundColor Yellow

        # すでにpush済みなら成功扱い
        git fetch origin main

        if ($LASTEXITCODE -ne 0) {
            throw "git fetchに失敗しました。"
        }

        $ahead = git rev-list --count origin/main..HEAD

        if ([int]$ahead -gt 0) {

            git push origin main

            if ($LASTEXITCODE -ne 0) {
                throw "git pushに失敗しました。"
            }
        }

        return
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
}

# =========================================================================
# 事前チェック
# =========================================================================

Write-Section "GitHub Issue → ComfyUI 自動動画生成"

Write-Host "Workflow: $WorkflowJson" -ForegroundColor DarkGray

if (!(Test-Path -LiteralPath $WorkflowJson)) {

    Write-Error "Workflow JSONがありません:"
    Write-Error $WorkflowJson
    exit 1
}

if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

    Write-Error "ComfyUI出力フォルダがありません:"
    Write-Error $ComfyOutputDir
    exit 1
}

# =========================================================================
# ComfyUI接続確認
# =========================================================================

Write-Host ""
Write-Host "ComfyUIの接続を確認しています..." -ForegroundColor Cyan

try {

    Invoke-RestMethod `
        -Uri $ComfySystemUrl `
        -Method Get `
        -ErrorAction Stop |
        Out-Null

    Write-Host "ComfyUI 接続OK" -ForegroundColor Green
}
catch {

    Write-Error "ComfyUIに接続できません: $ComfyUrl"
    exit 1
}

# =========================================================================
# Workflow読み込み
# =========================================================================

try {

    $workflowText = [System.IO.File]::ReadAllText(
        (Resolve-Path $WorkflowJson),
        $Utf8NoBom
    )

    $baseWorkflow = $workflowText | ConvertFrom-Json
}
catch {

    Write-Error "Workflow JSON読み込み失敗: $_"
    exit 1
}

# =========================================================================
# Placeholder確認
# =========================================================================

$placeholderCount = 0

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

Count-Placeholder $baseWorkflow

if ($placeholderCount -ne 1) {

    Write-Error "Workflow JSON内の $PromptPlaceholder が1個ではありません。現在: $placeholderCount"
    exit 1
}

Write-Host "Prompt placeholder OK" -ForegroundColor Green

# =========================================================================
# Issue取得
# =========================================================================

Write-Section "GitHubから未処理Issue取得"

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

    $issues = @(
        $issueJson | ConvertFrom-Json
    )
}
catch {

    Write-Error "Issue取得失敗: $_"
    exit 1
}

if ($issues.Count -eq 0) {

    Write-Host "処理対象のIssueはありません。" -ForegroundColor Green
    exit 0
}

Write-Host "$($issues.Count) 件のIssueを処理します。" -ForegroundColor Cyan

# =========================================================================
# Issue処理
# =========================================================================

foreach ($issue in $issues) {

    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "Processing Issue #$($issue.number): $($issue.title)" -ForegroundColor Magenta
    Write-Host "----------------------------------------" -ForegroundColor Gray

    try {

        # -------------------------------------------------------------
        # Issueの既存ジョブ情報
        # -------------------------------------------------------------

        $existingJob = Get-ExistingJobInfo `
            -IssueNumber ([int]$issue.number)

        # -------------------------------------------------------------
        # すでに完了している場合
        # -------------------------------------------------------------

        if ($existingJob.Completed) {

            Write-Host "このIssueは既に処理完了しています。" -ForegroundColor Green
            Write-Host "二重処理を防止するためスキップします。" -ForegroundColor Yellow

            continue
        }

        # -------------------------------------------------------------
        # Prompt
        # -------------------------------------------------------------

        $promptText = $issue.body

        if ([string]::IsNullOrWhiteSpace($promptText)) {

            $promptText = $issue.title
        }

        $promptText = $promptText.Trim()

        Write-Host "抽出されたプロンプト:" -ForegroundColor DarkGray
        Write-Host $promptText -ForegroundColor White

        $promptId = $existingJob.PromptId
        $videoFileName = $existingJob.VideoFileName

        # -------------------------------------------------------------
        # 既存ジョブがない場合だけComfyUIへ送信
        # -------------------------------------------------------------

        if ([string]::IsNullOrWhiteSpace($promptId)) {

            Write-Host ""
            Write-Host "新規ComfyUIジョブを作成します。" -ForegroundColor Cyan

            $workflow = $workflowText | ConvertFrom-Json

            # Prompt
            $replacementCount = 0

            Replace-PromptPlaceholder `
                -Object $workflow `
                -PromptText $promptText `
                -ReplacementCount ([ref]$replacementCount)

            if ($replacementCount -ne 1) {

                throw "Prompt placeholderの置換に失敗しました。"
            }

            # Seed
            $seed = [Int64](
                Get-Random `
                    -Minimum 1 `
                    -Maximum 2147483647
            )

            Set-RandomSeed `
                -Workflow $workflow `
                -Seed $seed

            # Payload
            $payloadObject = @{
                prompt = $workflow
            }

            $payload = $payloadObject |
                ConvertTo-Json `
                    -Depth 100 `
                    -Compress

            $payloadBytes = $Utf8NoBom.GetBytes($payload)

            # Send
            Write-Host "ComfyUI ジョブを送信中..." -ForegroundColor Cyan

            $response = Invoke-RestMethod `
                -Uri $ComfyPromptUrl `
                -Method Post `
                -Body $payloadBytes `
                -ContentType "application/json; charset=utf-8" `
                -ErrorAction Stop

            if ($null -eq $response.prompt_id) {

                throw "Prompt IDが返されませんでした。"
            }

            $promptId = [string]$response.prompt_id

            Write-Host "ジョブ送信成功！" -ForegroundColor Green
            Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow

            # ---------------------------------------------------------
            # ★ここが重要
            # Prompt IDを即座にIssueへ保存
            # ---------------------------------------------------------

            Add-JobComment `
                -IssueNumber ([int]$issue.number) `
                -PromptId $promptId `
                -Seed $seed

            Write-Host "Prompt IDをIssueへ記録しました。" -ForegroundColor Green
        }
        else {

            Write-Host ""
            Write-Host "既存のComfyUIジョブを検出しました。" -ForegroundColor Yellow
            Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow
            Write-Host "ComfyUIへ再送信しません。" -ForegroundColor Green
        }

        # -------------------------------------------------------------
        # History確認
        # -------------------------------------------------------------

        Write-Host ""
        Write-Host "動画生成状態を確認します。" -ForegroundColor Cyan

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
            Write-Host "[$minutes 分経過] ComfyUIの生成状態を確認中..." -ForegroundColor Cyan

            $historyResponse = Get-ComfyHistory `
                -PromptId $promptId

            if ($null -ne $historyResponse) {

                if (
                    $historyResponse.PSObject.Properties.Name `
                    -contains $promptId
                ) {

                    $history = $historyResponse.$promptId

                    # エラー確認
                    if ($history.PSObject.Properties.Name -contains "status") {

                        if (
                            $history.status.PSObject.Properties.Name `
                            -contains "status_str"
                        ) {

                            $status = [string]$history.status.status_str

                            Write-Host "Status: $status" -ForegroundColor DarkGray

                            if (
                                $status -match
                                '(?i)error|failed'
                            ) {

                                throw "ComfyUIジョブが失敗しました。Status=$status"
                            }
                        }
                    }

                    $videoOutput = Get-VideoOutputFromHistory `
                        -History $history

                    if ($null -ne $videoOutput) {

                        Write-Host "動画生成完了！" -ForegroundColor Green

                        break
                    }
                }
            }

            if ($elapsed -ge $MaxWaitSeconds) {

                throw "最大待機時間60分を超えました。"
            }

            Write-Host "まだ生成中です。5分後に再確認します。" -ForegroundColor DarkGray

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
            Write-Host "生成された動画:" -ForegroundColor Green
            Write-Host "  Filename : $videoFileName"
            Write-Host "  Subfolder: $($videoOutput.Subfolder)"
            Write-Host "  Type     : $($videoOutput.Type)"
        }

        # -------------------------------------------------------------
        # 動画コピー
        # -------------------------------------------------------------

        $videoFileName = Copy-ComfyVideo `
            -VideoOutput $videoOutput `
            -KnownFileName $videoFileName

        # -------------------------------------------------------------
        # Pages
        # -------------------------------------------------------------

        Update-Pages `
            -IssueNumber ([int]$issue.number) `
            -PromptText $promptText `
            -PromptId $promptId `
            -VideoFileName $videoFileName

        # -------------------------------------------------------------
        # Git
        # -------------------------------------------------------------

        Publish-Docs

        # -------------------------------------------------------------
        # 完了コメント
        # -------------------------------------------------------------

        Add-CompletedComment `
            -IssueNumber ([int]$issue.number) `
            -PromptId $promptId `
            -VideoFileName $videoFileName

        # -------------------------------------------------------------
        # Close
        # -------------------------------------------------------------

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
        Write-Host "Issueはクローズしません。" -ForegroundColor Yellow
        Write-Host "次回実行時には既存ジョブを確認します。" -ForegroundColor Yellow
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

        continue
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "すべてのIssue処理が終了しました。" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
