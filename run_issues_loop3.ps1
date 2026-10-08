# =========================================================================
# GitHub Issue -> ComfyUI -> Video -> GitHub Pages
# 常駐自動処理
#
# 完全復旧版 + git出力混入バグ修正版
#
# 修正ポイント:
#
#   1. Publish-Docs の git 出力が $State に混入しないように修正
#   2. Ensure-GitPublished で $null = Publish-Docs を使用
#   3. Ensure-Completed で $State が配列化していても防御
#   4. 状態ファイルに CompletedCommented / Closed が無い場合は自動補完
#   5. 完了コメントが既に存在する場合は重複投稿しない
#   6. Jobコメントが既に存在する場合は重複投稿しない
#   7. Issue が既に close されている場合は Closed=true として扱う
#   8. ComfyUI History の Prompt ID 参照を安全化
#
# =========================================================================

param(
    [string]$WorkflowJson = ".\workflows\video_fastvideo_fasth3_t2v.json",

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

$ComfyOutputDir = "F:\aiimg\StabilityMatrix\Data\Images\Text2Img\video"

$RepoVideoDir = "docs\videos"
$PagesFile = "docs\index.html"

# -------------------------------------------------------------
# ローカル状態保存先
#
# .automation-state/
#   issue-5.json
#   issue-6.json
#   ...
#
# Git管理対象外にすることを推奨
# -------------------------------------------------------------

$StateDir = ".automation-state"

$IssueLimit = 10

$CheckIntervalSeconds = 80

$MaxWaitSeconds = 3600

$PromptPlaceholder = "__TARGET_PROMPT__"

$SuccessMarker = "[COMFYUI-AUTO-COMPLETED]"
$JobMarker = "[COMFYUI-AUTO-JOB]"
$StateMarker = "[COMFYUI-AUTO-STATE]"

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
# ディレクトリ
# =========================================================================

function Ensure-StateDirectory {

    if (!(Test-Path -LiteralPath $StateDir)) {

        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
}

# =========================================================================
# Issue State Path
# =========================================================================

function Get-StatePath {
    param(
        [int]$IssueNumber
    )

    Ensure-StateDirectory

    return Join-Path -Path $StateDir -ChildPath "issue-$IssueNumber.json"
}

# =========================================================================
# Stateプロパティ補完
#
# 古いStateファイルや、途中で壊れたStateファイルに対して
# 必要なプロパティを自動で追加する。
# =========================================================================

function Ensure-StateProperties {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    if ($null -eq $State) {
        return
    }

    $defaults = [ordered]@{
        Version = 2

        IssueNumber = 0
        Title = ""
        Prompt = ""

        CreatedAt = $null
        UpdatedAt = $null

        PromptId = $null
        Seed = $null

        Submitted = $false
        JobCommented = $false

        Generated = $false

        VideoFileName = $null
        VideoSubfolder = $null

        VideoCopied = $false

        PagesUpdated = $false

        GitPublished = $false

        CompletedCommented = $false
        Closed = $false

        LastError = $null
        LastErrorAt = $null
    }

    foreach ($name in $defaults.Keys) {

        if (-not ($State.PSObject.Properties.Name -contains $name)) {

            $State | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] -Force
        }
    }
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
# Safe JSON Save
#
# 一時ファイルへ書いてからMoveする。
#
# PowerShellが途中で落ちても、
# 状態ファイルが壊れにくい。
# =========================================================================

function Save-State {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    # -------------------------------------------------------------
    # 保険:
    #
    # 過去バグで $State が配列になっている場合がある。
    # 配列なら PSCustomObject だけを取り出す。
    # -------------------------------------------------------------

    if ($State -is [array]) {

        $State =
            $State |
            Where-Object {
                $_ -is [pscustomobject]
            } |
            Select-Object -First 1
    }

    if ($null -eq $State) {

        throw "Save-State: Stateがnullです。"
    }

    Ensure-StateProperties $State

    Ensure-StateDirectory

    $issueNumber = [int]$State.IssueNumber

    $path = Get-StatePath -IssueNumber $issueNumber

    $tempPath = "$path.tmp"

    $State.UpdatedAt = (Get-Date).ToString("o")

    $json = $State | ConvertTo-Json -Depth 20

    [System.IO.File]::WriteAllText(
        $tempPath,
        $json,
        $Utf8NoBom
    )

    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

# =========================================================================
# State Load
# =========================================================================

function Load-State {
    param(
        [int]$IssueNumber
    )

    $path = Get-StatePath -IssueNumber $IssueNumber

    if (!(Test-Path -LiteralPath $path)) {

        return $null
    }

    try {

        $json = [System.IO.File]::ReadAllText(
            $path,
            $Utf8NoBom
        )

        $state = $json | ConvertFrom-Json

        Ensure-StateProperties $state

        return $state
    }
    catch {

        throw "Stateファイルを読み込めません: $path`n$_"
    }
}

# =========================================================================
# 新規State作成
# =========================================================================

function New-IssueState {
    param(
        [int]$IssueNumber,

        [string]$Title,

        [string]$Prompt
    )

    return [PSCustomObject]@{

        Version = 2

        IssueNumber = $IssueNumber

        Title = $Title

        Prompt = $Prompt

        CreatedAt = (Get-Date).ToString("o")

        UpdatedAt = (Get-Date).ToString("o")

        # -------------------------------------------------------------
        # ComfyUI
        # -------------------------------------------------------------

        PromptId = $null

        Seed = $null

        Submitted = $false

        JobCommented = $false

        # -------------------------------------------------------------
        # Generation
        # -------------------------------------------------------------

        Generated = $false

        VideoFileName = $null

        VideoSubfolder = $null

        # -------------------------------------------------------------
        # Local
        # -------------------------------------------------------------

        VideoCopied = $false

        # -------------------------------------------------------------
        # Pages
        # -------------------------------------------------------------

        PagesUpdated = $false

        # -------------------------------------------------------------
        # Git
        # -------------------------------------------------------------

        GitPublished = $false

        # -------------------------------------------------------------
        # Completion
        # -------------------------------------------------------------

        CompletedCommented = $false

        Closed = $false

        # -------------------------------------------------------------
        # Error
        # -------------------------------------------------------------

        LastError = $null

        LastErrorAt = $null
    }
}

# =========================================================================
# State Error記録
# =========================================================================

function Set-StateError {
    param(
        $State,

        [string]$Message
    )

    $State.LastError = $Message

    $State.LastErrorAt = (Get-Date).ToString("o")

    Save-State $State
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

    $data = $json | ConvertFrom-Json

    if ($null -eq $data) {

        return @()
    }

    return @($data.comments)
}

# =========================================================================
# GitHub上のJob情報
#
# 既存のIssueコメントから復旧するために使用。
#
# ローカルStateが消えても、
# GitHubコメントにPrompt IDがあれば復旧できる。
# =========================================================================

function Get-GitHubJobInfo {
    param(
        [int]$IssueNumber
    )

    $result = [PSCustomObject]@{
        Completed = $false
        PromptId = $null
        VideoFileName = $null
        Seed = $null
    }

    try {

        $comments = Get-IssueComments -IssueNumber $IssueNumber
    }
    catch {

        Write-Host "GitHubコメント取得に失敗しました。" -ForegroundColor Yellow

        return $result
    }

    foreach ($comment in @($comments)) {

        if ($null -eq $comment) {
            continue
        }

        $body = [string]$comment.body

        if ($body.Contains($SuccessMarker)) {

            $result.Completed = $true
        }

        if ($body.Contains($JobMarker)) {

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
# Jobコメント
#
# GitHub APIが失敗してもStateは残る。
# =========================================================================

function Add-JobComment {
    param(
        [int]$IssueNumber,

        [string]$PromptId,

        [Int64]$Seed
    )

    $comment = @"
$JobMarker
$StateMarker

ComfyUIジョブを送信しました。

Prompt ID: $PromptId
Seed: $Seed

このジョブは処理中です。
次回実行時にはPrompt IDを使用して再送信を防止します。
"@

    $result = & gh issue comment "$IssueNumber" --repo $GithubRepo --body $comment 2>&1

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
$StateMarker

ComfyUI動画生成が正常に完了しました。

Prompt ID: $PromptId
Video: $VideoFileName

GitHub Pagesへの反映も完了しています。
"@

    $result = & gh issue comment "$IssueNumber" --repo $GithubRepo --body $comment 2>&1

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

    $result = & gh issue close "$IssueNumber" --repo $GithubRepo --comment $comment 2>&1

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
# RandomNoise Seed
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

        if (
            $node.PSObject.Properties.Name `
            -contains "class_type"
        ) {

            if ([string]$node.class_type -eq "RandomNoise") {

                if ($null -eq $node.inputs) {
                    continue
                }

                if (
                    $node.inputs.PSObject.Properties.Name `
                    -contains "noise_seed"
                ) {

                    $node.inputs.noise_seed = $Seed

                    $found = $true

                    Write-Host "RandomNoise Seed: $Seed" -ForegroundColor DarkGray
                }
            }
        }
    }

    if (!$found) {

        throw "Workflow JSON内にRandomNoiseノードが見つかりません。"
    }
}

# =========================================================================
# Workflow読み込み
# =========================================================================

function Load-Workflow {

    if (!(Test-Path -LiteralPath $WorkflowJson)) {

        throw "Workflow JSONがありません: $WorkflowJson"
    }

    $resolvedPath = Resolve-Path $WorkflowJson

    $workflowText = [System.IO.File]::ReadAllText(
        $resolvedPath,
        $Utf8NoBom
    )

    $workflow = $workflowText | ConvertFrom-Json

    return [PSCustomObject]@{
        Text = $workflowText
        Object = $workflow
    }
}

# =========================================================================
# Placeholderカウント
# =========================================================================

function Count-Placeholder {
    param(
        $Object
    )

    if ($null -eq $Object) {
        return 0
    }

    if ($Object -is [string]) {

        if ($Object -eq $PromptPlaceholder) {
            return 1
        }

        return 0
    }

    if ($Object -is [System.Collections.IList]) {

        $count = 0

        foreach ($item in $Object) {

            if ($item -is [string]) {

                if ($item -eq $PromptPlaceholder) {
                    $count++
                }
            }
            else {

                $count += Count-Placeholder $item
            }
        }

        return $count
    }

    if ($Object -is [PSCustomObject]) {

        $count = 0

        foreach ($property in $Object.PSObject.Properties) {

            if ($property.Value -is [string]) {

                if ($property.Value -eq $PromptPlaceholder) {
                    $count++
                }
            }
            else {

                $count += Count-Placeholder $property.Value
            }
        }

        return $count
    }

    return 0
}

# =========================================================================
# Placeholder確認
# =========================================================================

function Test-WorkflowPlaceholder {
    param(
        $Workflow
    )

    $count = Count-Placeholder $Workflow

    if ($count -ne 1) {

        throw "Workflow JSON内の $PromptPlaceholder が1個ではありません。現在: $count"
    }

    Write-Host "Workflow placeholder OK" -ForegroundColor Green
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
# Historyから動画検索
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

                    if ($null -eq $item) {
                        continue
                    }

                    if ($null -eq $item.filename) {
                        continue
                    }

                    $extension =
                        [System.IO.Path]::GetExtension(
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
# Local Video Search
# =========================================================================

function Find-LocalVideo {
    param(
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {

        return $null
    }

    $directPath = Join-Path -Path $ComfyOutputDir -ChildPath $FileName

    if (Test-Path -LiteralPath $directPath) {

        return Get-Item -LiteralPath $directPath
    }

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
# Video Copy
# =========================================================================

function Copy-ComfyVideo {
    param(
        $VideoOutput,

        [string]$KnownFileName
    )

    $fileName = $null

    if ($null -ne $VideoOutput) {

        $fileName =
            [System.IO.Path]::GetFileName(
                $VideoOutput.Filename
            )
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {

        $fileName = $KnownFileName
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {

        throw "動画ファイル名を特定できません。"
    }

    $localVideo = Find-LocalVideo -FileName $fileName

    if ($null -eq $localVideo) {

        throw "ComfyUI出力フォルダに動画が見つかりません: $fileName"
    }

    if (!(Test-Path -LiteralPath $RepoVideoDir)) {

        New-Item -ItemType Directory -Path $RepoVideoDir -Force | Out-Null
    }

    $target = Join-Path -Path $RepoVideoDir -ChildPath $fileName

    # 同一ファイルならコピー不要
    if (Test-Path -LiteralPath $target) {

        $existing = Get-Item -LiteralPath $target

        if (
            $existing.Length -eq $localVideo.Length -and
            $existing.Length -gt 0
        ) {

            Write-Host "動画は既にdocs/videosへ存在します。" -ForegroundColor Yellow

            return $fileName
        }
    }

    Copy-Item -LiteralPath $localVideo.FullName -Destination $target -Force

    $targetInfo = Get-Item -LiteralPath $target

    if ($targetInfo.Length -le 0) {

        throw "コピーされた動画が0バイトです。"
    }

    Write-Host ""
    Write-Host "動画コピー完了:" -ForegroundColor Green

    Write-Host $target -ForegroundColor Green

    return $fileName
}

# =========================================================================
# GitHub Pages
# =========================================================================

function Update-Pages {
    param(
        [int]$IssueNumber,

        [string]$PromptText,

        [string]$PromptId,

        [string]$VideoFileName
    )

    if (!(Test-Path -LiteralPath "docs")) {

        New-Item -ItemType Directory -Path "docs" -Force | Out-Null
    }

    if (!(Test-Path -LiteralPath $RepoVideoDir)) {

        New-Item -ItemType Directory -Path $RepoVideoDir -Force | Out-Null
    }

    if (!(Test-Path -LiteralPath $PagesFile)) {

        $initialHtml = @"
<!DOCTYPE html>
<html lang="ja">
<head>

<meta charset="UTF-8">

<meta name="viewport"
      content="width=device-width, initial-scale=1.0">

<title>MiniMax H3 動画生成ジョブ履歴</title>

<style>

body {
    font-family: sans-serif;
    max-width: 900px;
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

.prompt-details {
    margin: 15px 0;
    background: #e7f1ff;
    border-radius: 6px;
    border: 1px solid #cfe2ff;
}

.prompt-summary {
    cursor: pointer;
    padding: 12px;
    font-weight: bold;
    color: #0d6efd;
    user-select: none;
}

.prompt-content {
    padding: 12px;
    border-top: 1px solid #cfe2ff;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    line-height: 1.6;
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
    word-break: break-all;
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

    $html =
        [System.IO.File]::ReadAllText(
            $PagesFile,
            $Utf8NoBom
        )

    if ($html -notmatch "<!-- JOBS_START -->") {

        throw "index.htmlにJOBS_STARTがありません。"
    }

    # -------------------------------------------------------------
    # 二重追加防止
    #
    # Prompt IDが既にindex.htmlに存在する場合、
    # 新しいカードを追加しない。
    # -------------------------------------------------------------

    if (
        $html.Contains(
            [System.Net.WebUtility]::HtmlEncode($PromptId)
        )
    ) {

        Write-Host "このPrompt IDは既にGitHub Pagesへ登録されています。" -ForegroundColor Yellow

        return
    }

    $safePrompt =
        [System.Net.WebUtility]::HtmlEncode(
            $PromptText
        )

    $safePromptId =
        [System.Net.WebUtility]::HtmlEncode(
            $PromptId
        )

    $safeVideoName =
        [System.Net.WebUtility]::HtmlEncode(
            $VideoFileName
        )

    $videoUrl =
        [System.Uri]::EscapeDataString(
            $VideoFileName
        )

    $date =
        Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $newJob = @"
<div class="job-card">

<div class="date">
処理日時: $date (Issue #$IssueNumber)
</div>

<details class="prompt-details">

<summary class="prompt-summary">
プロンプトを表示
</summary>

<div class="prompt-content">
$safePrompt
</div>

</details>

<div>
Prompt ID:
<span class="id">$safePromptId</span>
</div>

<video
    controls
    preload="metadata"
    src="videos/$videoUrl">
</video>

<div class="video-name">
$safeVideoName
</div>

</div>
"@

    $html =
        $html.Replace(
            "<!-- JOBS_START -->",
            "<!-- JOBS_START -->`r`n$newJob"
        )

    [System.IO.File]::WriteAllText(
        $PagesFile,
        $html,
        $Utf8NoBom
    )

    Write-Host "GitHub Pagesのindex.htmlを更新しました。" -ForegroundColor Green
}

# =========================================================================
# Git Publish
#
# ★重要修正:
#
# gitコマンドの出力をパイプラインへ流さない。
# 出力はすべて変数に受け取る。
#
# これにより Ensure-GitPublished の戻り値に
# git出力が混ざって $State が壊れるのを防ぐ。
# =========================================================================

function Publish-Docs {

    Write-Host ""
    Write-Host "GitHub Pagesへ成果物をプッシュします..." -ForegroundColor Cyan

    # -----------------------------------------------------------------
    # git add
    # -----------------------------------------------------------------

    $addOutput = git add -- docs/ 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "git addに失敗しました。`n$($addOutput -join "`n")"
    }

    # -----------------------------------------------------------------
    # git diff --cached --quiet
    #
    # 0: 変更なし
    # 1: staged変更あり
    # 2: gitコマンドエラー
    # -----------------------------------------------------------------

    $diffOutput = git diff --cached --quiet 2>&1

    $diffExitCode = $LASTEXITCODE

    if ($diffExitCode -eq 2) {

        throw "git diff --cachedでエラーが発生しました。`n$($diffOutput -join "`n")"
    }

    if ($diffExitCode -eq 0) {

        Write-Host "docs/に新しい変更はありません。" -ForegroundColor Yellow

        return
    }

    # -----------------------------------------------------------------
    # git commit
    # -----------------------------------------------------------------

    $commitOutput = git commit -m "Auto-update Pages [skip ci]" 2>&1

    if ($LASTEXITCODE -ne 0) {

        $statusOutput = git status --short 2>&1

        throw "git commitに失敗しました。`n$($commitOutput -join "`n")`n`n$($statusOutput -join "`n")"
    }

    # -----------------------------------------------------------------
    # git push
    # -----------------------------------------------------------------

    $pushOutput = git push origin main 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw "git pushに失敗しました。`n$($pushOutput -join "`n")"
    }

    # -----------------------------------------------------------------
    # 必要なら表示だけ行う。
    # Write-Host はパイプライン戻り値にはならない。
    # -----------------------------------------------------------------

    if ($pushOutput) {

        Write-Host ($pushOutput -join "`n") -ForegroundColor DarkGray
    }

    Write-Host "GitHubへのpush完了。" -ForegroundColor Green
}

# =========================================================================
# Git Identity
# =========================================================================

function Test-GitIdentity {

    $gitName = git config user.name
    $gitEmail = git config user.email

    if (
        [string]::IsNullOrWhiteSpace($gitName) -or
        [string]::IsNullOrWhiteSpace($gitEmail)
    ) {

        throw @"
Gitのuser.name / user.emailが設定されていません。

例:

git config --global user.name "Your Name"
git config --global user.email "you@example.com"
"@
    }

    Write-Host "Git user: $gitName <$gitEmail>" -ForegroundColor DarkGray
}

# =========================================================================
# GitHub CLI
# =========================================================================

function Test-GhConnection {

    $result = & gh auth status 2>&1

    if ($LASTEXITCODE -ne 0) {

        throw @"
GitHub CLIに接続できません。

gh auth login

詳細:
$result
"@
    }

    Write-Host "GitHub CLI 接続OK" -ForegroundColor Green
}

# =========================================================================
# Open Issues
# =========================================================================

function Get-OpenIssues {

    $issueJson =
        Invoke-GhJson @(
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

    if ([string]::IsNullOrWhiteSpace($issueJson)) {

        return @()
    }

    $parsed =
        $issueJson | ConvertFrom-Json

    if ($null -eq $parsed) {

        return @()
    }

    if ($parsed -is [System.Array]) {

        return @($parsed)
    }

    return @($parsed)
}

# =========================================================================
# State復旧
#
# 優先順位:
#
# 1. ローカルState
# 2. GitHubコメント
# 3. 新規作成
#
# =========================================================================

function Get-OrCreateIssueState {
    param(
        $Issue
    )

    [int]$issueNumber = 0

    if (
        ![int]::TryParse(
            ([string]$Issue.number),
            [ref]$issueNumber
        )
    ) {

        throw "Issue番号を整数に変換できません。"
    }

    $promptText = [string]$Issue.body

    if ([string]::IsNullOrWhiteSpace($promptText)) {

        $promptText = [string]$Issue.title
    }

    $promptText = $promptText.Trim()

    # -------------------------------------------------------------
    # 1. Local State
    # -------------------------------------------------------------

    $state = Load-State -IssueNumber $issueNumber

    if ($null -ne $state) {

        Ensure-StateProperties $state

        Write-Host "ローカルStateを復旧しました。" -ForegroundColor Green

        Save-State $state

        return $state
    }

    # -------------------------------------------------------------
    # 2. GitHub
    # -------------------------------------------------------------

    $githubJob =
        Get-GitHubJobInfo -IssueNumber $issueNumber

    $state =
        New-IssueState `
            -IssueNumber $issueNumber `
            -Title ([string]$Issue.title) `
            -Prompt $promptText

    if ($githubJob.Completed) {

        $state.PromptId =
            $githubJob.PromptId

        $state.VideoFileName =
            $githubJob.VideoFileName

        $state.CompletedCommented = $true

        Save-State $state

        return $state
    }

    if (
        ![string]::IsNullOrWhiteSpace(
            $githubJob.PromptId
        )
    ) {

        Write-Host "GitHubコメントからPrompt IDを復旧しました。" -ForegroundColor Yellow

        $state.PromptId =
            $githubJob.PromptId

        $state.Submitted = $true

        if ($null -ne $githubJob.Seed) {

            $state.Seed =
                [Int64]$githubJob.Seed
        }

        if (
            ![string]::IsNullOrWhiteSpace(
                $githubJob.VideoFileName
            )
        ) {

            $state.VideoFileName =
                $githubJob.VideoFileName
        }
    }

    Save-State $state

    return $state
}

# =========================================================================
# ComfyUI送信
#
# ★最重要
#
# POST成功
# ↓
# Prompt ID取得
# ↓
# 即State保存
#
# GitHubコメントはその後。
# =========================================================================

function Submit-New-ComfyJob {
    param(
        $State,

        $BaseWorkflow
    )

    if ($State.Submitted -and
        ![string]::IsNullOrWhiteSpace($State.PromptId)) {

        Write-Host "ComfyUIジョブは既に送信済みです。" -ForegroundColor Yellow

        return $State
    }

    # -------------------------------------------------------------
    # Workflow
    # -------------------------------------------------------------

    $workflow =
        $BaseWorkflow.Text | ConvertFrom-Json

    # -------------------------------------------------------------
    # Prompt
    # -------------------------------------------------------------

    $replacementCount = 0

    Replace-PromptPlaceholder `
        -Object $workflow `
        -PromptText ([string]$State.Prompt) `
        -ReplacementCount ([ref]$replacementCount)

    if ($replacementCount -ne 1) {

        throw "Prompt placeholderの置換に失敗しました。置換数=$replacementCount"
    }

    # -------------------------------------------------------------
    # Seed
    #
    # StateにSeedがある場合は再利用。
    # 新規時だけランダム生成。
    # -------------------------------------------------------------

    if ($null -eq $State.Seed) {

        $State.Seed =
            [Int64](
                Get-Random `
                    -Minimum 1 `
                    -Maximum 2147483647
            )
    }

    Set-RandomSeed `
        -Workflow $workflow `
        -Seed ([Int64]$State.Seed)

    # -------------------------------------------------------------
    # Payload
    # -------------------------------------------------------------

    $payloadObject = @{
        prompt = $workflow
    }

    $payload =
        $payloadObject |
        ConvertTo-Json `
            -Depth 100 `
            -Compress

    $payloadBytes =
        $Utf8NoBom.GetBytes($payload)

    # -------------------------------------------------------------
    # ComfyUI
    # -------------------------------------------------------------

    Write-Host ""
    Write-Host "ComfyUI ジョブを送信中..." -ForegroundColor Cyan

    $response =
        Invoke-RestMethod `
            -Uri $ComfyPromptUrl `
            -Method Post `
            -Body $payloadBytes `
            -ContentType "application/json; charset=utf-8" `
            -ErrorAction Stop

    if ($null -eq $response.prompt_id) {

        if (
            $response.PSObject.Properties.Name `
            -contains "error"
        ) {

            $errorText =
                $response.error | ConvertTo-Json -Depth 5

            throw "ComfyUIからエラーが返されました:`n$errorText"
        }

        throw "ComfyUIからPrompt IDが返されませんでした。"
    }

    $State.PromptId =
        [string]$response.prompt_id

    $State.Submitted = $true

    $State.LastError = $null
    $State.LastErrorAt = $null

    # =============================================================
    # ★★★ ここが二重送信防止の核心 ★★★
    #
    # GitHub commentより先にStateを保存。
    # =============================================================

    Save-State $State

    Write-Host ""
    Write-Host "ComfyUIジョブ送信成功！" -ForegroundColor Green

    Write-Host "Prompt ID: $($State.PromptId)" -ForegroundColor Yellow

    Write-Host "Seed: $($State.Seed)" -ForegroundColor Yellow

    return $State
}

# =========================================================================
# Job Comment
#
# 失敗してもStateはSubmitted=trueなので再送信されない。
# =========================================================================

function Ensure-JobComment {
    param(
        $State
    )

    if ($State.JobCommented) {

        return
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $State.PromptId
        )
    ) {

        throw "Prompt IDがありません。"
    }

    # -------------------------------------------------------------
    # 保険:
    #
    # GitHubに既にJobコメントが存在する場合は、
    # StateだけJobCommented=trueにする。
    #
    # 重複コメントを防ぐ。
    # -------------------------------------------------------------

    try {

        $comments = Get-IssueComments -IssueNumber ([int]$State.IssueNumber)

        foreach ($comment in @($comments)) {

            if ($null -eq $comment) {
                continue
            }

            $body = [string]$comment.body

            if ($body.Contains($JobMarker)) {

                $State.JobCommented = $true

                Save-State $State

                Write-Host "GitHubに既にJobコメントが存在するため、状態だけ更新しました。" -ForegroundColor Yellow

                return
            }
        }
    }
    catch {

        # 取得失敗は致命エラーにしない。
    }

    try {

        Add-JobComment `
            -IssueNumber ([int]$State.IssueNumber) `
            -PromptId ([string]$State.PromptId) `
            -Seed ([Int64]$State.Seed)

        $State.JobCommented = $true

        Save-State $State

        Write-Host "GitHubへJob情報を記録しました。" -ForegroundColor Green
    }
    catch {

        # -------------------------------------------------------------
        # 重要:
        #
        # コメント失敗は致命エラーにしない。
        #
        # Prompt IDは既にStateに保存済み。
        # -------------------------------------------------------------

        Write-Host ""
        Write-Host "GitHubへのJobコメント保存に失敗しました。" -ForegroundColor Yellow

        Write-Host $_ -ForegroundColor Yellow

        Write-Host ""
        Write-Host "ComfyUIジョブ自体は送信済みとして保持します。" -ForegroundColor Green

        Write-Host "次回ループでJobコメントのみ再試行します。" -ForegroundColor Green
    }
}

# =========================================================================
# Generation確認
# =========================================================================

function Ensure-Generated {
    param(
        $State
    )

    if ($State.Generated) {

        Write-Host "生成済み動画情報をStateから復旧しました。" -ForegroundColor Green

        return $State
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $State.PromptId
        )
    ) {

        throw "Prompt IDがありません。"
    }

    Write-Host ""
    Write-Host "動画生成状態を確認します。" -ForegroundColor Cyan

    $startTime = Get-Date

    while ($true) {

        $elapsed =
            (
                (Get-Date) - $startTime
            ).TotalSeconds

        $minutes =
            [math]::Floor(
                $elapsed / 60
            )

        Write-Host ""
        Write-Host "[$minutes 分経過] ComfyUI History確認中..." -ForegroundColor Cyan

        $promptId = [string]$State.PromptId

        $historyResponse =
            Get-ComfyHistory -PromptId $promptId

        if ($null -ne $historyResponse) {

            if (
                $historyResponse.PSObject.Properties.Name `
                -contains $promptId
            ) {

                $history = $historyResponse.$promptId

                # -----------------------------------------------------
                # Status
                # -----------------------------------------------------

                if (
                    $history.PSObject.Properties.Name `
                    -contains "status"
                ) {

                    if (
                        $history.status.PSObject.Properties.Name `
                        -contains "status_str"
                    ) {

                        $status =
                            [string]$history.status.status_str

                        Write-Host "Status: $status" -ForegroundColor DarkGray

                        if (
                            $status -match
                            '(?i)error|failed'
                        ) {

                            throw "ComfyUIジョブが失敗しました。Status=$status"
                        }
                    }
                }

                # -----------------------------------------------------
                # Video
                # -----------------------------------------------------

                $videoOutput =
                    Get-VideoOutputFromHistory -History $history

                if ($null -ne $videoOutput) {

                    $State.Generated = $true

                    $State.VideoFileName =
                        [System.IO.Path]::GetFileName(
                            $videoOutput.Filename
                        )

                    $State.VideoSubfolder =
                        [string]$videoOutput.Subfolder

                    $State.LastError = $null
                    $State.LastErrorAt = $null

                    Save-State $State

                    Write-Host ""
                    Write-Host "動画生成完了！" -ForegroundColor Green

                    return $State
                }
            }
        }

        if ($elapsed -ge $MaxWaitSeconds) {

            throw "最大待機時間60分を超えました。Prompt ID=$($State.PromptId)"
        }

        Write-Host "まだ生成中です。1分後に再確認します。" -ForegroundColor DarkGray

        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

# =========================================================================
# Video Copy
# =========================================================================

function Ensure-VideoCopied {
    param(
        $State
    )

    if ($State.VideoCopied) {

        $target =
            Join-Path `
                $RepoVideoDir `
                ([string]$State.VideoFileName)

        if (Test-Path -LiteralPath $target) {

            Write-Host "動画コピー済みです。" -ForegroundColor Green

            return $State
        }

        # Stateだけある場合は再コピー可能
        $State.VideoCopied = $false
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $State.VideoFileName
        )
    ) {

        throw "VideoFileNameがありません。"
    }

    $videoOutput =
        [PSCustomObject]@{
            Filename = [string]$State.VideoFileName
            Subfolder = [string]$State.VideoSubfolder
            Type = "output"
        }

    $fileName =
        Copy-ComfyVideo `
            -VideoOutput $videoOutput `
            -KnownFileName ([string]$State.VideoFileName)

    $State.VideoFileName = $fileName

    $State.VideoCopied = $true

    Save-State $State

    return $State
}

# =========================================================================
# Pages
# =========================================================================

function Ensure-PagesUpdated {
    param(
        $State
    )

    if ($State.PagesUpdated) {

        # -------------------------------------------------------------
        # 実際にPrompt IDが存在するか確認
        # -------------------------------------------------------------

        if (Test-Path -LiteralPath $PagesFile) {

            $html =
                [System.IO.File]::ReadAllText(
                    $PagesFile,
                    $Utf8NoBom
                )

            if (
                $html.Contains(
                    [System.Net.WebUtility]::HtmlEncode(
                        [string]$State.PromptId
                    )
                )
            ) {

                Write-Host "GitHub Pages更新済みです。" -ForegroundColor Green

                return $State
            }
        }

        $State.PagesUpdated = $false
    }

    Update-Pages `
        -IssueNumber ([int]$State.IssueNumber) `
        -PromptText ([string]$State.Prompt) `
        -PromptId ([string]$State.PromptId) `
        -VideoFileName ([string]$State.VideoFileName)

    $State.PagesUpdated = $true

    Save-State $State

    return $State
}

# =========================================================================
# Git Publish
# =========================================================================

function Ensure-GitPublished {
    param(
        $State
    )

    if ($State.GitPublished) {

        Write-Host "GitHub Pagesは既にpush済みです。" -ForegroundColor Green

        return $State
    }

    # -------------------------------------------------------------
    # ★重要:
    #
    # Publish-Docsの出力をパイプラインに流さない。
    # これにより $State が配列になるバグを防ぐ。
    # -------------------------------------------------------------

    $null = Publish-Docs

    # -------------------------------------------------------------
    # push成功後のみtrue
    # -------------------------------------------------------------

    $State.GitPublished = $true

    Save-State $State

    return $State
}

# =========================================================================
# Completion
# =========================================================================

function Ensure-Completed {
    param(
        $State
    )

    # -------------------------------------------------------------
    # 保険:
    #
    # 過去バグで $State が配列になっている場合がある。
    # 配列なら PSCustomObject だけを取り出す。
    # -------------------------------------------------------------

    if ($State -is [array]) {

        $State =
            $State |
            Where-Object {
                $_ -is [pscustomobject]
            } |
            Select-Object -First 1
    }

    if ($null -eq $State) {

        return $null
    }

    Ensure-StateProperties $State

    # -------------------------------------------------------------
    # 保険:
    #
    # GitHubに既に完了コメントが存在する場合は、
    # StateだけCompletedCommented=trueにする。
    #
    # 重複完了コメントを防ぐ。
    # -------------------------------------------------------------

    if (!$State.CompletedCommented) {

        try {

            $comments = Get-IssueComments -IssueNumber ([int]$State.IssueNumber)

            foreach ($comment in @($comments)) {

                if ($null -eq $comment) {
                    continue
                }

                $body = [string]$comment.body

                if ($body.Contains($SuccessMarker)) {

                    $State.CompletedCommented = $true

                    Save-State $State

                    Write-Host "GitHubに既に完了コメントが存在するため、状態だけ更新しました。" -ForegroundColor Yellow

                    break
                }
            }
        }
        catch {

            # 取得失敗は致命エラーにしない。
        }
    }

    # -------------------------------------------------------------
    # CompletedCommented
    # -------------------------------------------------------------

    if (!$State.CompletedCommented) {

        try {

            Add-CompletedComment `
                -IssueNumber ([int]$State.IssueNumber) `
                -PromptId ([string]$State.PromptId) `
                -VideoFileName ([string]$State.VideoFileName)

            $State.CompletedCommented = $true

            Save-State $State

            Write-Host "完了コメントを投稿しました。" -ForegroundColor Green
        }
        catch {

            Write-Host ""
            Write-Host "完了コメント投稿に失敗しました。" -ForegroundColor Yellow

            Write-Host $_ -ForegroundColor Yellow

            Write-Host "次回ループで再試行します。" -ForegroundColor Yellow

            return $State
        }
    }

    # -------------------------------------------------------------
    # Close
    #
    # 完了コメント成功後のみCloseする。
    # -------------------------------------------------------------

    if (
        $State.CompletedCommented -and
        !$State.Closed
    ) {

        try {

            Close-Issue `
                -IssueNumber ([int]$State.IssueNumber) `
                -PromptId ([string]$State.PromptId) `
                -VideoFileName ([string]$State.VideoFileName)

            $State.Closed = $true

            Save-State $State

            Write-Host "IssueをCloseしました。" -ForegroundColor Green
        }
        catch {

            $err = $_.Exception.Message

            # ---------------------------------------------------------
            # 既にcloseされている場合はClosed=trueとして扱う
            # ---------------------------------------------------------

            if ($err -match '(?i)already closed') {

                $State.Closed = $true

                Save-State $State

                Write-Host "Issueは既にCloseされているため、状態だけClosed=trueにしました。" -ForegroundColor Yellow
            }
            else {

                Write-Host ""
                Write-Host "Issue Closeに失敗しました。" -ForegroundColor Yellow

                Write-Host $_ -ForegroundColor Yellow

                Write-Host "次回ループで再試行します。" -ForegroundColor Yellow
            }
        }
    }

    return $State
}

# =========================================================================
# Issue処理
# =========================================================================

function Process-Issue {
    param(
        $Issue,

        $BaseWorkflow
    )

    [int]$issueNumber = 0

    if (
        ![int]::TryParse(
            ([string]$Issue.number),
            [ref]$issueNumber
        )
    ) {

        throw "Issue番号を整数に変換できません。"
    }

    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Gray

    Write-Host "Processing Issue #$issueNumber : $($Issue.title)" -ForegroundColor Magenta

    Write-Host "----------------------------------------" -ForegroundColor Gray

    # -------------------------------------------------------------
    # State復旧 / 作成
    # -------------------------------------------------------------

    $State =
        Get-OrCreateIssueState -Issue $Issue

    # -------------------------------------------------------------
    # 保険
    # -------------------------------------------------------------

    if ($State -is [array]) {

        $State =
            $State |
            Where-Object {
                $_ -is [pscustomobject]
            } |
            Select-Object -First 1
    }

    if ($null -eq $State) {

        Write-Host "Stateを取得できませんでした。" -ForegroundColor Red

        return
    }

    Ensure-StateProperties $State

    # -------------------------------------------------------------
    # 既にClose済み
    # -------------------------------------------------------------

    if ($State.Closed) {

        Write-Host "State上では既に完了済みです。" -ForegroundColor Green

        return
    }

    # -------------------------------------------------------------
    # Prompt
    # -------------------------------------------------------------

    Write-Host ""
    Write-Host "Prompt:" -ForegroundColor DarkGray

    if ($State.Prompt.Length -gt 500) {

        Write-Host (
            $State.Prompt.Substring(0,500) +
            "..."
        ) -ForegroundColor White
    }
    else {

        Write-Host $State.Prompt -ForegroundColor White
    }

    # =============================================================
    # Phase 1
    # ComfyUI Submit
    # =============================================================

    if (
        !$State.Submitted -or
        [string]::IsNullOrWhiteSpace(
            $State.PromptId
        )
    ) {

        $State =
            Submit-New-ComfyJob `
                -State $State `
                -BaseWorkflow $BaseWorkflow
    }
    else {

        Write-Host ""
        Write-Host "既存ComfyUIジョブを使用します。" -ForegroundColor Yellow

        Write-Host "Prompt ID: $($State.PromptId)" -ForegroundColor Yellow

        Write-Host "再送信は行いません。" -ForegroundColor Green
    }

    # =============================================================
    # Phase 2
    # GitHub Job Comment
    # =============================================================

    Ensure-JobComment -State $State

    # =============================================================
    # Phase 3
    # Generation
    # =============================================================

    $State =
        Ensure-Generated -State $State

    # =============================================================
    # Phase 4
    # Video Copy
    # =============================================================

    $State =
        Ensure-VideoCopied -State $State

    # =============================================================
    # Phase 5
    # Pages
    # =============================================================

    $State =
        Ensure-PagesUpdated -State $State

    # =============================================================
    # Phase 6
    # Git Push
    # =============================================================

    $State =
        Ensure-GitPublished -State $State

    # =============================================================
    # Phase 7
    # Completion
    # =============================================================

    $State =
        Ensure-Completed -State $State

    # -------------------------------------------------------------
    # Final
    # -------------------------------------------------------------

    if ($State.Closed) {

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green

        Write-Host "Issue #$issueNumber 完全完了" -ForegroundColor Green

        Write-Host "Prompt ID: $($State.PromptId)" -ForegroundColor Green

        Write-Host "Video: $($State.VideoFileName)" -ForegroundColor Green

        Write-Host "========================================" -ForegroundColor Green
    }
    else {

        Write-Host ""
        Write-Host "Issue #$issueNumber は処理途中です。" -ForegroundColor Yellow

        Write-Host "次回ループでStateから再開します。" -ForegroundColor Yellow
    }
}

# =========================================================================
# 初期チェック
# =========================================================================

function Test-InitialEnvironment {

    Write-Host ""
    Write-Host "初期チェック中..." -ForegroundColor Cyan

    # -------------------------------------------------------------
    # State
    # -------------------------------------------------------------

    Ensure-StateDirectory

    Write-Host "State directory OK: $StateDir" -ForegroundColor Green

    # -------------------------------------------------------------
    # Comfy output
    # -------------------------------------------------------------

    if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

        throw "ComfyUI出力フォルダがありません: $ComfyOutputDir"
    }

    # -------------------------------------------------------------
    # Git
    # -------------------------------------------------------------

    Test-GitIdentity

    # -------------------------------------------------------------
    # GitHub
    # -------------------------------------------------------------

    Test-GhConnection

    # -------------------------------------------------------------
    # ComfyUI
    # -------------------------------------------------------------

    try {

        Invoke-RestMethod `
            -Uri $ComfySystemUrl `
            -Method Get `
            -ErrorAction Stop |
            Out-Null

        Write-Host "ComfyUI 接続OK" -ForegroundColor Green
    }
    catch {

        throw "ComfyUIに接続できません: $ComfyUrl"
    }

    # -------------------------------------------------------------
    # Workflow
    # -------------------------------------------------------------

    $baseWorkflow =
        Load-Workflow

    Test-WorkflowPlaceholder -Workflow $baseWorkflow.Object

    Write-Host ""
    Write-Host "初期チェック完了。" -ForegroundColor Green

    return $baseWorkflow
}

# =========================================================================
# 起動
# =========================================================================

Write-Section "GitHub Issue -> ComfyUI -> Video -> GitHub Pages 完全復旧版"

Write-Host ""
Write-Host "Workflow : $WorkflowJson" -ForegroundColor DarkGray

Write-Host "State    : $StateDir" -ForegroundColor DarkGray

Write-Host "Issue確認: $LoopIntervalSeconds 秒ごと" -ForegroundColor DarkGray

Write-Host "生成待機 : 最大60分" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Ctrl+C で終了します。" -ForegroundColor Yellow

# =========================================================================
# 初期チェック
# =========================================================================

try {

    $BaseWorkflow =
        Test-InitialEnvironment
}
catch {

    Write-Host ""
    Write-Host "初期チェック失敗。" -ForegroundColor Red

    Write-Host $_ -ForegroundColor Red

    exit 1
}

# =========================================================================
# 常駐ループ
# =========================================================================

while ($true) {

    try {

        Write-Section "GitHub Issue確認"

        Write-Host "Open Issueを確認しています..." -ForegroundColor Cyan

        $issues =
            Get-OpenIssues

        if ($null -eq $issues) {

            $issues = @()
        }

        Write-Host ""

        if ($issues.Count -eq 0) {

            Write-Host "処理対象のIssueはありません。" -ForegroundColor Green
        }
        else {

            Write-Host "$($issues.Count) 件のOpen Issueを検出しました。" -ForegroundColor Cyan

            foreach ($issue in $issues) {

                try {

                    Process-Issue `
                        -Issue $issue `
                        -BaseWorkflow $BaseWorkflow
                }
                catch {

                    Write-Host ""
                    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

                    Write-Host "Issue #$($issue.number) の処理に失敗しました。" -ForegroundColor Red

                    Write-Host ""

                    Write-Host $_ -ForegroundColor Red

                    Write-Host ""
                    Write-Host "Issueはクローズしません。" -ForegroundColor Yellow

                    Write-Host "Stateが残っているため、次回は途中から再開します。" -ForegroundColor Yellow

                    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

                    continue
                }
            }
        }

        Write-Host ""
        Write-Host "今回のIssueチェックが終了しました。" -ForegroundColor Green

        Write-Host ""
        Write-Host "次回GitHub確認まで $LoopIntervalSeconds 秒待機します。" -ForegroundColor DarkGray

        Start-Sleep -Seconds $LoopIntervalSeconds
    }
    catch {

        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

        Write-Host "メインループでエラーが発生しました。" -ForegroundColor Red

        Write-Host ""

        Write-Host $_ -ForegroundColor Red

        Write-Host ""
        Write-Host "$LoopIntervalSeconds 秒後に再試行します。" -ForegroundColor Yellow

        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

        Start-Sleep -Seconds $LoopIntervalSeconds
    }
}
