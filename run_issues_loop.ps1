# =========================================================================
# GitHub Issue → ComfyUI → Video → GitHub Pages
# 常駐自動処理 安定版
#
# 動作:
#
#   1. GitHubのOpen Issueを定期確認
#   2. Issue本文をComfyUIプロンプトとして使用
#   3. Workflow JSON内の __TARGET_PROMPT__ を置換
#   4. RandomNoiseのnoise_seedを毎回ランダム化
#   5. ComfyUIへジョブ送信
#   6. Prompt IDをIssueへ即座に記録
#   7. 次回ループではPrompt IDを検出して再送信を防止
#   8. 最大60分、5分間隔で生成完了を確認
#   9. 動画をdocs/videosへコピー
#  10. docs/index.html更新
#  11. プロンプトはGitHub Pages上で折りたたみ表示
#  12. Git commit / push
#  13. 成功したらIssueへ完了コメント
#  14. IssueをClose
#  15. 5分待機して次のIssueを確認
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

# 最大待機時間
$MaxWaitSeconds = 3600

# Workflow内のプロンプト置換文字列
$PromptPlaceholder = "__TARGET_PROMPT__"

# Issueコメント用マーカー
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

    $data = $json | ConvertFrom-Json

    if ($null -eq $data) {
        return @()
    }

    return @($data.comments)
}

# =========================================================================
# 既存ジョブ情報取得
#
# ★重要
#
# -like "*[MARKER]*" は使用しない。
#
# [ と ] は PowerShell のワイルドカード構文で
# 特別な意味を持つため。
#
# Contains() を使用する。
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

        if ($null -eq $comment) {
            continue
        }

        $body = [string]$comment.body

        # -------------------------------------------------------------
        # 完了済み確認
        #
        # -like は使わない
        # -------------------------------------------------------------

        if ($body.Contains($SuccessMarker)) {

            $result.Completed = $true
        }

        # -------------------------------------------------------------
        # ジョブ情報
        # -------------------------------------------------------------

        if ($body.Contains($JobMarker)) {

            # Prompt ID
            $match = [regex]::Match(
                $body,
                'Prompt ID:\s*([a-f0-9\-]+)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $result.PromptId = $match.Groups[1].Value
            }

            # Video
            $match = [regex]::Match(
                $body,
                'Video:\s*(\S+)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $result.VideoFileName = $match.Groups[1].Value
            }

            # Seed
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
# Issueへジョブ情報記録
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
        "$IssueNumber" `
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
        "$IssueNumber" `
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
        "$IssueNumber" `
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

        if (
            $node.PSObject.Properties.Name `
            -contains "class_type"
        ) {

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

                    if ($null -eq $item) {
                        continue
                    }

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

    $directPath = Join-Path `
        $ComfyOutputDir `
        $FileName

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

        throw "ComfyUI出力フォルダに動画が見つかりません: $fileName"
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
# GitHub Pages
#
# ★プロンプトをdetails/summaryで折りたたむ
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
    # index.htmlが存在しない場合
    # -------------------------------------------------------------

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
    # 新しいジョブカード
    #
    # details / summary により
    # プロンプトは折りたたまれる
    # -------------------------------------------------------------

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

    # -------------------------------------------------------------
    # 最新ジョブを先頭に追加
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
    # docsだけstage
    # -------------------------------------------------------------

    git add -- docs/

    if ($LASTEXITCODE -ne 0) {

        throw "git addに失敗しました。"
    }

    # -------------------------------------------------------------
    # stageされた変更があるか
    # -------------------------------------------------------------

    git diff --cached --quiet

    $diffExitCode = $LASTEXITCODE

    # 0 = 差分なし
    # 1 = 差分あり
    # その他 = エラー

    if ($diffExitCode -eq 2) {

        throw "git diff --cachedでエラーが発生しました。"
    }

    # -------------------------------------------------------------
    # 差分なし
    # -------------------------------------------------------------

    if ($diffExitCode -eq 0) {

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
# Git設定確認
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

    # ダミー設定の検出
    if (
        $gitName -eq "Your Name" -or
        $gitEmail -eq "you@example.com"
    ) {

        Write-Host ""
        Write-Host `
            "警告: Gitのuser.name / user.emailがサンプル値です。" `
            -ForegroundColor Yellow

        Write-Host `
            "必要なら以下を変更してください。" `
            -ForegroundColor Yellow

        Write-Host `
            'git config --global user.name "Your Name"' `
            -ForegroundColor DarkGray

        Write-Host `
            'git config --global user.email "you@example.com"' `
            -ForegroundColor DarkGray
    }

    Write-Host `
        "Git user: $gitName <$gitEmail>" `
        -ForegroundColor DarkGray
}

# =========================================================================
# GitHub CLI確認
# =========================================================================

function Test-GhConnection {

    try {

        $result = & gh auth status 2>&1

        if ($LASTEXITCODE -ne 0) {

            throw "gh auth status failed: $result"
        }

        Write-Host `
            "GitHub CLI 接続OK" `
            -ForegroundColor Green
    }
    catch {

        throw @"
GitHub CLIに接続できません。

以下を実行してログインしてください:

gh auth login

詳細:
$_
"@
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
# Issue取得
#
# ★重要
#
# 1件の場合でも2件以上の場合でも、
# 必ず「Issueオブジェクトの配列」にする。
#
# これにより
#
# System.Object[] → System.Int32
#
# の問題を防止する。
# =========================================================================

function Get-OpenIssues {

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

    if ([string]::IsNullOrWhiteSpace($issueJson)) {

        return @()
    }

    $parsed = $issueJson | ConvertFrom-Json

    if ($null -eq $parsed) {

        return @()
    }

    # -------------------------------------------------------------
    # ConvertFrom-Jsonが配列を返した場合
    # -------------------------------------------------------------

    if ($parsed -is [System.Array]) {

        $result = @()

        foreach ($item in $parsed) {

            if ($null -ne $item) {

                $result += $item
            }
        }

        return $result
    }

    # -------------------------------------------------------------
    # 1件だけの場合
    # -------------------------------------------------------------

    return @($parsed)
}

# =========================================================================
# Issue 1件処理
# =========================================================================

function Process-Issue {
    param(
        $Issue,

        $BaseWorkflow
    )

    # -------------------------------------------------------------
    # Issue番号を安全に取得
    # -------------------------------------------------------------

    $rawNumber = $Issue.number

    if ($rawNumber -is [System.Array]) {

        throw `
            "Issue.numberが配列になっています。値: $($rawNumber -join ', ')"
    }

    [int]$issueNumber = 0

    if (
        ![int]::TryParse(
            ([string]$rawNumber),
            [ref]$issueNumber
        )
    ) {

        throw `
            "Issue番号を整数に変換できません。値: $rawNumber"
    }

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
            "このIssueは既に完了済みです。" `
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

    # コンソールでは長すぎるプロンプトを全部表示しない
    if ($promptText.Length -gt 500) {

        Write-Host `
            ($promptText.Substring(0, 500) + "...") `
            -ForegroundColor White

        Write-Host `
            "(長いプロンプトのためコンソール表示を省略)" `
            -ForegroundColor DarkGray
    }
    else {

        Write-Host `
            $promptText `
            -ForegroundColor White
    }

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
                "Prompt placeholderの置換に失敗しました。置換数=$replacementCount"
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

        $payloadBytes = $Utf8NoBom.GetBytes($payload)

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

        Write-Host ""
        Write-Host `
            "ジョブ送信成功！" `
            -ForegroundColor Green

        Write-Host `
            "Prompt ID: $promptId" `
            -ForegroundColor Yellow

        # ---------------------------------------------------------
        # ★最重要
        #
        # ComfyUI送信成功直後にPrompt IDを保存
        #
        # Gitや動画処理で失敗しても、
        # 次回ループでは再送信されない。
        # ---------------------------------------------------------

        Add-JobComment `
            -IssueNumber $issueNumber `
            -PromptId $promptId `
            -Seed $seed

        Write-Host `
            "Prompt IDをIssueへ保存しました。" `
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
    # ComfyUI History監視
    # -------------------------------------------------------------

    Write-Host ""
    Write-Host `
        "動画生成を最大60分待機します。" `
        -ForegroundColor Cyan

    Write-Host `
        "5分ごとにComfyUI Historyを確認します。" `
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
                # Status
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
                            $status -match
                            '(?i)error|failed'
                        ) {

                            throw `
                                "ComfyUIジョブが失敗しました。Status=$status"
                        }
                    }
                }

                # -------------------------------------------------
                # 動画検索
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
            else {

                Write-Host `
                    "HistoryにPrompt IDがまだありません。" `
                    -ForegroundColor DarkGray
            }
        }
        else {

            Write-Host `
                "ComfyUI Historyを取得できませんでした。" `
                -ForegroundColor DarkGray
        }

        # -------------------------------------------------------------
        # 最大待機時間
        # -------------------------------------------------------------

        if ($elapsed -ge $MaxWaitSeconds) {

            throw `
                "最大待機時間60分を超えました。Prompt ID=$promptId"
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
    # GitHub Pages
    # -------------------------------------------------------------

    Update-Pages `
        -IssueNumber $issueNumber `
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
# ComfyUI出力フォルダ
# -------------------------------------------------------------

if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

    Write-Error `
        "ComfyUI出力フォルダがありません: $ComfyOutputDir"

    exit 1
}

# -------------------------------------------------------------
# Git
# -------------------------------------------------------------

try {

    Test-GitIdentity
}
catch {

    Write-Error $_

    exit 1
}

# -------------------------------------------------------------
# GitHub CLI
# -------------------------------------------------------------

try {

    Test-GhConnection
}
catch {

    Write-Error $_

    exit 1
}

# -------------------------------------------------------------
# ComfyUI
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
# Workflow
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

        $issues = Get-OpenIssues

        # -------------------------------------------------------------
        # Issueなし
        # -------------------------------------------------------------

        if ($null -eq $issues) {

            $issues = @()
        }

        Write-Host ""

        if ($issues.Count -eq 0) {

            Write-Host `
                "処理対象のIssueはありません。" `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "$($issues.Count) 件のOpen Issueを検出しました。" `
                -ForegroundColor Cyan

            # ---------------------------------------------------------
            # Issueを順番に処理
            # ---------------------------------------------------------

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

                    # -------------------------------------------------
                    # 1件失敗しても次のIssueへ
                    # -------------------------------------------------

                    continue
                }
            }
        }

        # -------------------------------------------------------------
        # 次回確認
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
        # メインループエラー
        #
        # GitHub CLI / ネットワーク / ComfyUI等
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
            "$LoopIntervalSeconds 秒後に再試行します。" `
            -ForegroundColor Yellow

        Write-Host `
            "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" `
            -ForegroundColor Red

        Start-Sleep `
            -Seconds $LoopIntervalSeconds
    }
}
