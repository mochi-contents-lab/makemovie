=========================================================================
GitHub Issue → ComfyUI → Video → GitHub Pages 常駐自動処理
#

主な仕様
#

- GitHub Open Issueを定期確認
- Issue本文をComfyUI Workflowの TARGETPROMPT_ に投入
- RandomNoise の noise_seed をランダム化
- ComfyUIへ送信
- Prompt IDをGitHub Issueへ即時記録
- Prompt IDが既に存在する場合は再送信しない
- ComfyUI Historyから生成完了を監視
- 生成動画をdocs/videosへコピー
- docs/index.htmlへ履歴追加
- Git commit / push
- 完了コメント
- Issue Close
- 5分ごとに常駐ループ
#

GitHubコメントは gh issue comment のGraphQLではなく
gh api のREST APIを使用
#

Workflow JSONではプロンプト部分だけ
#

"TARGETPROMPT_"
#

としてください。
#

=========================================================================
=========================================================================
設定
=========================================================================
$GithubRepo = "mochi-contents-lab/makemovie"

$ComfyUrl = "http://127.0.0.1:8188"

$ComfyPromptUrl = "$ComfyUrl/prompt" $ComfyHistoryUrl = "$ComfyUrl/history" $ComfySystemUrl = "$ComfyUrl/system_stats"

$ComfyOutputDir = "F:\aiimg\StabilityMatrix\Data\Images\Text2Img\video"

$RepoVideoDir = "docs\videos" $PagesFile = "docs\index.html"

1回のIssue確認で取得するOpen Issue数
$IssueLimit = 10

Issue確認間隔
$CheckIntervalSeconds = 300

ComfyUI動画生成の最大待機時間
$MaxWaitSeconds = 3600

$PromptPlaceholder = "TARGETPROMPT_"

ジョブ登録マーカー
$JobMarker = "[COMFYUI-AUTO-JOB]"

完了マーカー
$SuccessMarker = "[COMFYUI-AUTO-COMPLETED]"

=========================================================================
UTF-8
=========================================================================
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try { [Console]::InputEncoding = $Utf8NoBom [Console]::OutputEncoding = $Utf8NoBom } catch {}

$OutputEncoding = $Utf8NoBom

=========================================================================
表示
=========================================================================
function Write-Section { param( [string]$Text )

Write-Host "" Write-Host "========================================" -ForegroundColor DarkGray Write-Host $Text -ForegroundColor Cyan Write-Host "========================================" -ForegroundColor DarkGray }

=========================================================================
gh JSON
=========================================================================
function Invoke-GhJson { param( [Parameter(Mandatory = $true)] [string[]]$Arguments )

$psi = New-Object System.Diagnostics.ProcessStartInfo

$psi.FileName = "gh"

$escapedArguments = @()

foreach ($arg in $Arguments) {

if ($arg -match '[\s"]') {

$escaped = $arg.Replace('', '\').Replace('"', '"')

$escapedArguments += '"' + $escaped + '"' } else {

$escapedArguments += $arg } }

$psi.Arguments = $escapedArguments -join " "

$psi.UseShellExecute = $false $psi.CreateNoWindow = $true $psi.RedirectStandardOutput = $true $psi.RedirectStandardError = $true

try { $psi.StandardOutputEncoding = $Utf8NoBom $psi.StandardErrorEncoding = $Utf8NoBom } catch {}

$process = New-Object System.Diagnostics.Process $process.StartInfo = $psi

[void]$process.Start()

$stdout = $process.StandardOutput.ReadToEnd() $stderr = $process.StandardError.ReadToEnd()

$process.WaitForExit()

if ($process.ExitCode -ne 0) {

throw "gh command failed: $stderr" }

return $stdout }

=========================================================================
GitHub REST API
#

GraphQLを使わず gh api を使用する。
=========================================================================
function Invoke-GhApi { param( [Parameter(Mandatory = $true)] [string[]]$Arguments )

$result = & gh api @Arguments 2>&1

if ($LASTEXITCODE -ne 0) {

$message = ($result | Out-String).Trim()

throw "GitHub REST API failed: $message" }

return $result }

=========================================================================
Issueコメント取得
=========================================================================
function Get-IssueComments { param( [int]$IssueNumber )

$json = Invoke-GhJson @( "issue", "view", "$IssueNumber", "--repo", $GithubRepo, "--json", "comments" )

return ($json | ConvertFrom-Json).comments }

=========================================================================
既存ジョブ情報取得
#

-like は使用しない。
#

[COMFYUI-AUTO-JOB]
の [] をPowerShellのワイルドカードとして解釈させない。
=========================================================================
function Get-ExistingJobInfo { param( [int]$IssueNumber )

$comments = Get-IssueComments -IssueNumber $IssueNumber

$result = [PSCustomObject]@{ Completed = $false PromptId = $null VideoFileName = $null Seed = $null }

foreach ($comment in @($comments)) {

$body = [string]$comment.body

# ------------------------------------------------------------- # 完了判定 # Containsなので [] はワイルドカードにならない # -------------------------------------------------------------

if ($body.Contains($SuccessMarker)) {

$result.Completed = $true }

# ------------------------------------------------------------- # ジョブマーカー # -------------------------------------------------------------

if ($body.Contains($JobMarker)) {

$match = [regex]::Match( $body, 'Prompt ID:\s*([a-f0-9-]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase )

if ($match.Success) {

$result.PromptId = $match.Groups[1].Value }

$match = [regex]::Match( $body, 'Video:\s*(\S+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase )

if ($match.Success) {

$result.VideoFileName = $match.Groups[1].Value }

$match = [regex]::Match( $body, 'Seed:\s*(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase )

if ($match.Success) {

$result.Seed = $match.Groups[1].Value } } }

return $result }

=========================================================================
Job Comment
#

重要:
gh issue comment は使用しない。
REST APIを使用する。
=========================================================================
function Add-JobComment { param( [int]$IssueNumber,

[string]$PromptId,

[Int64]$Seed )

$comment = @" $JobMarker

ComfyUIジョブを送信しました。

Prompt ID: $PromptId Seed: $Seed

このジョブは処理中です。 次回実行時にはPrompt IDを使用して再送信を防止します。 "@

Write-Host "GitHub Issueへジョブ情報を保存します..." -ForegroundColor Cyan

gh api の -f body= はREST APIのJSON bodyとして送信される
$result = Invoke-GhApi @( "repos/$GithubRepo/issues/$IssueNumber/comments", "-X", "POST", "-f", "body=$comment" )

Write-Host "GitHub Issueへのジョブ情報保存完了。" -ForegroundColor Green }

=========================================================================
完了コメント
=========================================================================
function Add-CompletedComment { param( [int]$IssueNumber,

[string]$PromptId,

[string]$VideoFileName )

$comment = @" $SuccessMarker

ComfyUI動画生成が正常に完了しました。

Prompt ID: $PromptId Video: $VideoFileName

GitHub Pagesへの反映も完了しています。 "@

Write-Host "GitHub Issueへ完了コメントを保存します..." -ForegroundColor Cyan

Invoke-GhApi @( "repos/$GithubRepo/issues/$IssueNumber/comments", "-X", "POST", "-f", "body=$comment" ) | Out-Null

Write-Host "完了コメント保存完了。" -ForegroundColor Green }

=========================================================================
Issue Close
#

コメントもREST APIで投稿。
Close自体もREST API。
=========================================================================
function Close-Issue { param( [int]$IssueNumber,

[string]$PromptId,

[string]$VideoFileName )

$comment = @" ComfyUIへのジョブ送信、動画生成、動画回収、GitHub Pages更新が正常に完了したため、このIssueを自動クローズしました。

Prompt ID: $PromptId Video: $VideoFileName "@

Write-Host "Issue完了コメントを保存します..." -ForegroundColor Cyan

Invoke-GhApi @( "repos/$GithubRepo/issues/$IssueNumber/comments", "-X", "POST", "-f", "body=$comment" ) | Out-Null

Write-Host "IssueをCloseします..." -ForegroundColor Cyan

Invoke-GhApi @( "repos/$GithubRepo/issues/$IssueNumber", "-X", "PATCH", "-f", "state=closed" ) | Out-Null

Write-Host "Issue #$IssueNumber をCloseしました。" -ForegroundColor Green }

=========================================================================
Prompt置換
=========================================================================
function Replace-PromptPlaceholder { param( $Object,

[string]$PromptText,

[ref]$ReplacementCount )

if ($null -eq $Object) { return }

if ($Object -is [System.Collections.IList]) {

for ($i = 0; $i -lt $Object.Count; $i++) {

if ($Object[$i] -is [string]) {

if ($Object[$i] -eq $PromptPlaceholder) {

$Object[$i] = $PromptText $ReplacementCount.Value++ } } else {

Replace-PromptPlaceholder -Object $Object[$i] -PromptText $PromptText ` -ReplacementCount $ReplacementCount } }

return }

if ($Object -is [PSCustomObject]) {

foreach ($property in $Object.PSObject.Properties) {

if ($property.Value -is [string]) {

if ($property.Value -eq $PromptPlaceholder) {

$property.Value = $PromptText $ReplacementCount.Value++ } } else {

Replace-PromptPlaceholder -Object $property.Value -PromptText $PromptText ` -ReplacementCount $ReplacementCount } } } }

=========================================================================
Seed変更
=========================================================================
function Set-RandomSeed { param( $Workflow,

[Int64]$Seed )

$found = $false

foreach ($property in $Workflow.PSObject.Properties) {

$node = $property.Value

if ($null -eq $node) { continue }

if ($node.PSObject.Properties.Name -contains "class_type") {

if ([string]$node.class_type -eq "RandomNoise") {

if ($node.inputs.PSObject.Properties.Name -contains "noise_seed") {

$node.inputs.noise_seed = $Seed

$found = $true

Write-Host "RandomNoise Seed: $Seed" -ForegroundColor DarkGray } } } }

if (!$found) {

throw "RandomNoiseノードが見つかりません。" } }

=========================================================================
ComfyUI History
=========================================================================
function Get-ComfyHistory { param( [string]$PromptId )

try {

return Invoke-RestMethod -Uri "$ComfyHistoryUrl/$PromptId" -Method Get ` -ErrorAction Stop } catch {

return $null } }

=========================================================================
Historyから動画を探す
=========================================================================
function Get-VideoOutputFromHistory { param( $History )

if ($null -eq $History) { return $null }

if ($History.PSObject.Properties.Name -notcontains "outputs") { return $null }

foreach ($nodeProperty in $History.outputs.PSObject.Properties) {

$nodeOutput = $nodeProperty.Value

if ($null -eq $nodeOutput) { continue }

foreach ($outputName in @("videos", "images")) {

if ($nodeOutput.PSObject.Properties.Name -contains $outputName) {

foreach ($item in @($nodeOutput.$outputName)) {

if ($null -eq $item.filename) { continue }

$extension = [System.IO.Path]::GetExtension( [string]$item.filename )

if ( $extension -match '(?i)^.(mp4|webm|mov|mkv|avi)$' ) {

return [PSCustomObject]@{ Filename = [string]$item.filename Subfolder = [string]$item.subfolder Type = [string]$item.type NodeId = [string]$nodeProperty.Name } } } } } }

return $null }

=========================================================================
動画をローカルから探す
=========================================================================
function Find-LocalVideo { param( [string]$FileName )

if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }

$directPath = Join-Path $ComfyOutputDir $FileName

if (Test-Path -LiteralPath $directPath) {

return Get-Item -LiteralPath $directPath }

$found = Get-ChildItem -Path $ComfyOutputDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $FileName } | Select-Object -First 1

return $found }

=========================================================================
動画コピー
=========================================================================
function Copy-ComfyVideo { param( $VideoOutput,

[string]$KnownFileName )

$fileName = $null

if ($VideoOutput -ne $null) {

$fileName = [System.IO.Path]::GetFileName( $VideoOutput.Filename ) }

if ([string]::IsNullOrWhiteSpace($fileName)) {

$fileName = $KnownFileName }

if ([string]::IsNullOrWhiteSpace($fileName)) {

throw "動画ファイル名を特定できません。" }

if (!(Test-Path -LiteralPath $RepoVideoDir)) {

New-Item -ItemType Directory -Path $RepoVideoDir ` -Force | Out-Null }

$localVideo = Find-LocalVideo ` -FileName $fileName

if ($null -eq $localVideo) {

throw "ComfyUI出力フォルダに動画が見つかりません: $fileName" }

$target = Join-Path $RepoVideoDir $fileName

Copy-Item -LiteralPath $localVideo.FullName -Destination $target ` -Force

$targetInfo = Get-Item -LiteralPath $target

if ($targetInfo.Length -le 0) {

throw "コピーされた動画が0バイトです。" }

Write-Host "動画コピー完了:" -ForegroundColor Green Write-Host $target -ForegroundColor Green

return $fileName }

=========================================================================
Prompt表示
#

長いプロンプトは最初の数行だけ表示。
=========================================================================
function Show-PromptPreview { param( [string]$PromptText )

$lines = $PromptText -split "r?n"

$maxLines = 8

if ($lines.Count -le $maxLines) {

Write-Host $PromptText -ForegroundColor White

return }

for ($i = 0; $i -lt $maxLines; $i++) {

Write-Host $lines[$i] -ForegroundColor White }

Write-Host "" Write-Host "... (長いプロンプトのためコンソール表示を省略)" -ForegroundColor DarkGray Write-Host "全 $($lines.Count) 行" -ForegroundColor DarkGray }

=========================================================================
HTML Prompt
#

<details>で折りたたみ可能にする。
=========================================================================
function New-PromptHtml { param( [string]$PromptText )

$safePrompt = [System.Net.WebUtility]::HtmlEncode( $PromptText )

return @" <details class="prompt-details"> <summary>プロンプトを表示 / 折りたたむ</summary> <div class="prompt">$safePrompt</div> </details> "@ }

=========================================================================
index.html作成・更新
=========================================================================
function Update-Pages { param( [int]$IssueNumber,

[string]$PromptText,

[string]$PromptId,

[string]$VideoFileName )

if (!(Test-Path -LiteralPath "docs")) {

New-Item -ItemType Directory -Path "docs" ` -Force | Out-Null }

if (!(Test-Path -LiteralPath $RepoVideoDir)) {

New-Item -ItemType Directory -Path $RepoVideoDir ` -Force | Out-Null }

if (!(Test-Path -LiteralPath $PagesFile)) {

$initialHtml = @" <!DOCTYPE html> <html lang="ja">

<head>

<meta charset="UTF-8">

<meta name="viewport" content="width=device-width, initial-scale=1.0">

<title>MiniMax H3 動画生成ジョブ履歴</title>

<style>

body { font-family: sans-serif; max-width: 900px; margin: 0 auto; padding: 20px; background: #f8f9fa; color: #333; }

h1 { color: #212529; border-bottom: 3px solid #0d6efd; padding-bottom: 10px; }

.job-card { background: white; padding: 20px; margin-bottom: 20px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); border: 1px solid #dee2e6; }

.date { color: #6c757d; font-size: 0.85em; margin-bottom: 10px; }

.prompt-details { margin: 15px 0; border: 1px solid #cfe2ff; border-radius: 6px; background: #f8fbff; }

.prompt-details summary { cursor: pointer; font-weight: bold; color: #0d6efd; padding: 12px; user-select: none; }

.prompt-details summary:hover { background: #e7f1ff; }

.prompt { color: #333; background: #e7f1ff; padding: 15px; border-top: 1px solid #cfe2ff; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.6; }

.id { font-family: monospace; background: #e9ecef; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; word-break: break-all; }

video { width: 100%; border-radius: 6px; margin-top: 15px; background: #000; }

</style>

</head>

<body>

<h1>🎬 MiniMax H3 動画生成ジョブ履歴</h1>

<!-- JOBSSTART --> <!-- JOBSEND -->

</body>

</html> "@

[System.IO.File]::WriteAllText( $PagesFile, $initialHtml, $Utf8NoBom ) }

$html = [System.IO.File]::ReadAllText( $PagesFile, $Utf8NoBom )

if ($html -notmatch "<!-- JOBS_START -->") {

throw "index.htmlにJOBS_STARTがありません。" }

$safePromptId = [System.Net.WebUtility]::HtmlEncode( $PromptId )

$safeVideoName = [System.Net.WebUtility]::HtmlEncode( $VideoFileName )

$videoUrl = [System.Uri]::EscapeDataString( $VideoFileName )

$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$promptHtml = New-PromptHtml ` -PromptText $PromptText

$newJob = @" <div class="job-card">

<div class="date"> 処理日時: $date (Issue #$IssueNumber) </div>

$promptHtml

<div> Prompt ID: <span class="id">$safePromptId</span> </div>

<video controls preload="metadata" src="videos/$videoUrl"></video>

<div> $safeVideoName </div>

</div> "@

$html = $html.Replace( "<!-- JOBSSTART -->", "<!-- JOBSSTART -->rn$newJob" )

[System.IO.File]::WriteAllText( $PagesFile, $html, $Utf8NoBom )

Write-Host "GitHub Pages更新完了。" -ForegroundColor Green }

=========================================================================
Git Publish
=========================================================================
function Publish-Docs {

Write-Host "" Write-Host "GitHub Pagesへ成果物をプッシュします..." -ForegroundColor Cyan

git add -- docs/

if ($LASTEXITCODE -ne 0) {

throw "git addに失敗しました。" }

git diff --cached --quiet

if ($LASTEXITCODE -eq 0) {

Write-Host "docs/に新しい変更はありません。" -ForegroundColor Yellow

git fetch origin main

if ($LASTEXITCODE -ne 0) {

throw "git fetchに失敗しました。" }

$aheadText = git rev-list --count origin/main..HEAD

if ($LASTEXITCODE -ne 0) {

throw "git rev-listに失敗しました。" }

$ahead = [int]$aheadText

if ($ahead -gt 0) {

git push origin main

if ($LASTEXITCODE -ne 0) {

throw "git pushに失敗しました。" } }

return }

git commit ` -m "Auto-update Pages [skip ci]"

if ($LASTEXITCODE -ne 0) {

throw "git commitに失敗しました。" }

git push origin main

if ($LASTEXITCODE -ne 0) {

throw "git pushに失敗しました。" }

Write-Host "GitHubへのpush完了。" -ForegroundColor Green }

=========================================================================
初期チェック
=========================================================================
Write-Section "GitHub Issue → ComfyUI → Video → GitHub Pages 常駐自動処理"

Write-Host "Workflow : $WorkflowJson" -ForegroundColor DarkGray Write-Host "Issue確認: $CheckIntervalSeconds 秒ごと" -ForegroundColor DarkGray Write-Host "生成待機 : 最大60分" -ForegroundColor DarkGray Write-Host "" Write-Host "Ctrl+C で終了します。" -ForegroundColor Yellow

Write-Host "" Write-Host "初期チェック中..." -ForegroundColor Cyan

-------------------------------------------------------------------------
Workflow
-------------------------------------------------------------------------
if (!(Test-Path -LiteralPath $WorkflowJson)) {

Write-Error "Workflow JSONがありません:" Write-Error $WorkflowJson exit 1 }

-------------------------------------------------------------------------
Comfy output
-------------------------------------------------------------------------
if (!(Test-Path -LiteralPath $ComfyOutputDir)) {

Write-Error "ComfyUI出力フォルダがありません:" Write-Error $ComfyOutputDir exit 1 }

-------------------------------------------------------------------------
Git
-------------------------------------------------------------------------
$gitUserName = (git config --get user.name 2>$null) $gitUserEmail = (git config --get user.email 2>$null)

if ( [string]::IsNullOrWhiteSpace($gitUserName) -or [string]::IsNullOrWhiteSpace($gitUserEmail) ) {

Write-Warning "Gitのuser.name / user.emailが設定されていません。"

Write-Host '必要なら以下を実行してください。' -ForegroundColor Yellow Write-Host 'git config --global user.name "Your Name"' -ForegroundColor Yellow Write-Host 'git config --global user.email "you@example.com"' -ForegroundColor Yellow } else {

Write-Host "Git user: $gitUserName <$gitUserEmail>" -ForegroundColor DarkGray

if ( $gitUserName -eq "Your Name" -or $gitUserEmail -eq "you@example.com" ) {

Write-Warning "Gitのuser.name / user.emailがサンプル値です。" Write-Host '必要なら以下を変更してください。' -ForegroundColor Yellow Write-Host 'git config --global user.name "Your Name"' -ForegroundColor Yellow Write-Host 'git config --global user.email "you@example.com"' -ForegroundColor Yellow } }

-------------------------------------------------------------------------
GitHub CLI
-------------------------------------------------------------------------
try {

& gh auth status 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {

throw "GitHub CLI認証に失敗しました。" }

Write-Host "GitHub CLI 接続OK" -ForegroundColor Green } catch {

Write-Error $_ exit 1 }

-------------------------------------------------------------------------
ComfyUI
-------------------------------------------------------------------------
try {

Invoke-RestMethod -Uri $ComfySystemUrl -Method Get ` -ErrorAction Stop | Out-Null

Write-Host "ComfyUI 接続OK" -ForegroundColor Green } catch {

Write-Error "ComfyUIに接続できません: $ComfyUrl" exit 1 }

-------------------------------------------------------------------------
Workflow読み込み
-------------------------------------------------------------------------
try {

$workflowText = [System.IO.File]::ReadAllText( (Resolve-Path $WorkflowJson), $Utf8NoBom )

$baseWorkflow = $workflowText | ConvertFrom-Json } catch {

Write-Error "Workflow JSON読み込み失敗: $_" exit 1 }

=========================================================================
Placeholder確認
=========================================================================
$placeholderCount = 0

function Count-Placeholder { param( $Object )

if ($null -eq $Object) { return }

if ($Object -is [System.Collections.IList]) {

foreach ($item in $Object) {

if ($item -is [string]) {

if ($item -eq $PromptPlaceholder) {

$script:placeholderCount++ } } else {

Count-Placeholder $item } }

return }

if ($Object -is [PSCustomObject]) {

foreach ($property in $Object.PSObject.Properties) {

if ($property.Value -is [string]) {

if ($property.Value -eq $PromptPlaceholder) {

$script:placeholderCount++ } } else {

Count-Placeholder $property.Value } } } }

Count-Placeholder $baseWorkflow

if ($placeholderCount -ne 1) {

Write-Error "Workflow JSON内の $PromptPlaceholder が1個ではありません。現在: $placeholderCount" exit 1 }

Write-Host "Workflow placeholder OK" -ForegroundColor Green

Write-Host "" Write-Host "初期チェック完了。" -ForegroundColor Green

=========================================================================
メイン常駐ループ
=========================================================================
while ($true) {

try {

Write-Section "GitHub Issue確認"

Write-Host "Open Issueを確認しています..." -ForegroundColor Cyan

try {

$issueJson = Invoke-GhJson @( "issue", "list", "--repo", $GithubRepo, "--state", "open", "--limit", "$IssueLimit", "--json", "number,title,body" )

$issues = @( $issueJson | ConvertFrom-Json ) } catch {

Write-Host "" Write-Host "Issue取得失敗:" -ForegroundColor Red Write-Host $_ -ForegroundColor Red

$issues = @() }

if ($issues.Count -eq 0) {

Write-Host "処理対象のOpen Issueはありません。" -ForegroundColor Green } else {

Write-Host "" Write-Host "$($issues.Count) 件のOpen Issueを検出しました。" -ForegroundColor Cyan

# ============================================================= # Issue処理 # =============================================================

foreach ($issue in $issues) {

Write-Host "" Write-Host "----------------------------------------" -ForegroundColor Gray Write-Host "Processing Issue #$($issue.number) : $($issue.title)" -ForegroundColor Magenta Write-Host "----------------------------------------" -ForegroundColor Gray

try {

$issueNumber = [int]$issue.number

# ----------------------------------------------------- # 既存ジョブ確認 # -----------------------------------------------------

$existingJob = Get-ExistingJobInfo ` -IssueNumber $issueNumber

# ----------------------------------------------------- # 完了済み # -----------------------------------------------------

if ($existingJob.Completed) {

Write-Host "このIssueは既に完了しています。" -ForegroundColor Green Write-Host "スキップします。" -ForegroundColor Yellow

continue }

# ----------------------------------------------------- # Prompt # -----------------------------------------------------

$promptText = [string]$issue.body

if ([string]::IsNullOrWhiteSpace($promptText)) {

$promptText = [string]$issue.title }

$promptText = $promptText.Trim()

Write-Host "" Write-Host "抽出されたプロンプト:" -ForegroundColor DarkGray

Show-PromptPreview ` -PromptText $promptText

# ----------------------------------------------------- # Existing Job # -----------------------------------------------------

$promptId = $existingJob.PromptId $videoFileName = $existingJob.VideoFileName

# ===================================================== # 新規Job # =====================================================

if ([string]::IsNullOrWhiteSpace($promptId)) {

Write-Host "" Write-Host "新規ComfyUIジョブを作成します。" -ForegroundColor Cyan

# ------------------------------------------------- # Workflowコピー # -------------------------------------------------

$workflow = $workflowText | ConvertFrom-Json

# ------------------------------------------------- # Prompt # -------------------------------------------------

$replacementCount = 0

Replace-PromptPlaceholder -Object $workflow -PromptText $promptText ` -ReplacementCount ([ref]$replacementCount)

if ($replacementCount -ne 1) {

throw "Prompt placeholderの置換に失敗しました。" }

# ------------------------------------------------- # Seed # -------------------------------------------------

$seed = Int64

Set-RandomSeed -Workflow $workflow -Seed $seed

# ------------------------------------------------- # Payload # -------------------------------------------------

$payloadObject = @{ prompt = $workflow }

$payload = $payloadObject | ConvertTo-Json -Depth 100 -Compress

$payloadBytes = $Utf8NoBom.GetBytes($payload)

# ------------------------------------------------- # ComfyUI送信 # -------------------------------------------------

Write-Host "ComfyUI ジョブを送信中..." -ForegroundColor Cyan

$response = Invoke-RestMethod -Uri $ComfyPromptUrl -Method Post -Body $payloadBytes -ContentType "application/json; charset=utf-8" ` -ErrorAction Stop

if ($null -eq $response.prompt_id) {

throw "Prompt IDが返されませんでした。" }

$promptId = [string]$response.prompt_id

Write-Host "" Write-Host "ジョブ送信成功！" -ForegroundColor Green Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow

# ================================================= # 最重要 # # Prompt IDをGitHubへ保存 # # REST APIを使用。 # =================================================

try {

Add-JobComment -IssueNumber $issueNumber -PromptId $promptId ` -Seed $seed

} catch {

# ------------------------------------------------- # ここが重要。 # # ComfyUIには既に送信済み。 # # GitHub記録だけ失敗した場合、 # 同じJobを再送信してはいけない。 # # 現在のPrompt IDを使ってHistory監視を続ける。 # -------------------------------------------------

Write-Host "" Write-Host "GitHubへのジョブ記録に失敗しました。" -ForegroundColor Red Write-Host $_ -ForegroundColor Red

Write-Host "" Write-Host "ComfyUIには既に送信済みです。" -ForegroundColor Yellow Write-Host "この実行中はPrompt IDを保持して処理を続行します。" -ForegroundColor Yellow Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow

# ------------------------------------------------- # ここではthrowしない。 # ComfyUIジョブを最後まで処理する。 # -------------------------------------------------

Write-Host "" Write-Host "GitHubコメントは動画完了後に再試行します。" -ForegroundColor Cyan } } else {

Write-Host "" Write-Host "既存のComfyUIジョブを検出しました。" -ForegroundColor Yellow Write-Host "Prompt ID: $promptId" -ForegroundColor Yellow Write-Host "ComfyUIへ再送信しません。" -ForegroundColor Green

if (![string]::IsNullOrWhiteSpace($existingJob.Seed)) {

Write-Host "Seed: $($existingJob.Seed)" -ForegroundColor DarkGray } }

# ===================================================== # History監視 # =====================================================

Write-Host "" Write-Host "動画生成状態を確認します。" -ForegroundColor Cyan

$startTime = Get-Date

$videoOutput = $null

while ($true) {

$elapsed = ( (Get-Date) - $startTime ).TotalSeconds

$minutes = [math]::Floor( $elapsed / 60 )

Write-Host "" Write-Host "[$minutes 分経過] ComfyUIの生成状態を確認中..." -ForegroundColor Cyan

$historyResponse = Get-ComfyHistory ` -PromptId $promptId

if ($null -ne $historyResponse) {

if ( $historyResponse.PSObject.Properties.Name ` -contains $promptId ) {

$history = $historyResponse.$promptId

# ----------------------------------------- # Status # -----------------------------------------

if ( $history.PSObject.Properties.Name ` -contains "status" ) {

if ( $history.status.PSObject.Properties.Name ` -contains "status_str" ) {

$status = [string]$history.status.status_str

Write-Host "Status: $status" -ForegroundColor DarkGray

if ( $status -match '(?i)error|failed' ) {

throw "ComfyUIジョブが失敗しました。Status=$status" } } }

# ----------------------------------------- # Video # -----------------------------------------

$videoOutput = Get-VideoOutputFromHistory ` -History $history

if ($null -ne $videoOutput) {

Write-Host "" Write-Host "動画生成完了！" -ForegroundColor Green

break } } }

if ($elapsed -ge $MaxWaitSeconds) {

throw "最大待機時間60分を超えました。" }

Write-Host "まだ生成中です。5分後に再確認します。" -ForegroundColor DarkGray

Start-Sleep ` -Seconds $CheckIntervalSeconds }

# ===================================================== # Video Filename # =====================================================

if ($null -ne $videoOutput) {

$videoFileName = [System.IO.Path]::GetFileName( $videoOutput.Filename )

Write-Host "" Write-Host "生成された動画:" -ForegroundColor Green Write-Host " Filename : $videoFileName" Write-Host " Subfolder: $($videoOutput.Subfolder)" Write-Host " Type : $($videoOutput.Type)" }

# ===================================================== # Video Copy # =====================================================

$videoFileName = Copy-ComfyVideo -VideoOutput $videoOutput -KnownFileName $videoFileName

# ===================================================== # Pages # =====================================================

Update-Pages -IssueNumber $issueNumber -PromptText $promptText -PromptId $promptId -VideoFileName $videoFileName

# ===================================================== # Git # =====================================================

Publish-Docs

# ===================================================== # 完了コメント # =====================================================

Add-CompletedComment -IssueNumber $issueNumber -PromptId $promptId ` -VideoFileName $videoFileName

# ===================================================== # Close # =====================================================

Close-Issue -IssueNumber $issueNumber -PromptId $promptId ` -VideoFileName $videoFileName

Write-Host "" Write-Host "Issue #$issueNumber 完了！" -ForegroundColor Green Write-Host "Prompt ID: $promptId" -ForegroundColor Green Write-Host "Video: $videoFileName" -ForegroundColor Green } catch {

Write-Host "" Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red Write-Host "Issue #$($issue.number) の処理に失敗しました。" -ForegroundColor Red Write-Host $_ -ForegroundColor Red Write-Host "" Write-Host "Issueはクローズしません。" -ForegroundColor Yellow Write-Host "次回ループで既存ジョブを確認します。" -ForegroundColor Yellow Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red

continue } } }

Write-Host "" Write-Host "今回のIssueチェックが終了しました。" -ForegroundColor Green } catch {

Write-Host "" Write-Host "========================================" -ForegroundColor Red Write-Host "メインループでエラーが発生しました。" -ForegroundColor Red Write-Host $_ -ForegroundColor Red Write-Host "========================================" -ForegroundColor Red }

=========================================================================
次回ループ
=========================================================================
Write-Host "" Write-Host "次回GitHub確認まで $CheckIntervalSeconds 秒待機します。" -ForegroundColor DarkGray

try {

Start-Sleep ` -Seconds $CheckIntervalSeconds } catch {

Write-Host "" Write-Host "常駐処理を終了します。" -ForegroundColor Yellow

break } }