param(
    [Parameter(Mandatory = $true)][string]$CodexBin,
    [string]$AppPath,
    [ValidateSet("present", "absent", "any")][string]$ExpectMarker = "any",
    [string]$LogsDb,
    [string]$UpstreamRef,
    [string]$PatchFile,
    [string]$ExpectedBlob = "cc31d50b13268417fa34d8262a7c3682cda8912e"
)

$marker = "retrying remote compaction with fallback model"
$fallbackModel = "gpt-5.4-mini"
$sourceModel = "gpt-5.5"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$targetPath = "codex-rs/core/src/compact_remote.rs"

if (-not $PatchFile) {
    $PatchFile = Join-Path $repoRoot "patches/openai-codex-compact-fallback.patch"
}

if (-not (Test-Path -LiteralPath $CodexBin -PathType Leaf)) {
    Write-Error "Codex binary not found: $CodexBin"
    exit 1
}

if (-not $AppPath -and $CodexBin.EndsWith("/Contents/Resources/codex")) {
    $AppPath = Resolve-Path (Join-Path (Split-Path -Parent $CodexBin) "../..")
}

$appVersion = "unknown"
$appBuild = "unknown"
if ($AppPath -and (Test-Path -LiteralPath (Join-Path $AppPath "Contents/Info.plist") -PathType Leaf) -and (Test-Path -LiteralPath "/usr/libexec/PlistBuddy" -PathType Leaf)) {
    $infoPlist = Join-Path $AppPath "Contents/Info.plist"
    $appVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $infoPlist 2>$null)
    if (-not $appVersion) { $appVersion = "unknown" }
    $appBuild = (& /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $infoPlist 2>$null)
    if (-not $appBuild) { $appBuild = "unknown" }
}

$cliVersion = (& $CodexBin --version 2>$null | Select-Object -First 1)
if (-not $cliVersion) { $cliVersion = "unknown" }

$content = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($CodexBin))
$markerPresent = $content.Contains($marker) -and $content.Contains($fallbackModel) -and $content.Contains($sourceModel)

if ($ExpectMarker -eq "present" -and -not $markerPresent) {
    Write-Error "patch_marker=missing"
    exit 1
}

if ($ExpectMarker -eq "absent" -and $markerPresent) {
    Write-Error "patch_marker=present"
    exit 1
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $CodexBin
Write-Output "codex_bin=$CodexBin"
Write-Output "app_path=$(if ($AppPath) { $AppPath } else { 'unknown' })"
Write-Output "app_version=$appVersion"
Write-Output "app_build=$appBuild"
Write-Output "codex_cli_version=$cliVersion"
Write-Output "patch_marker=$markerPresent"
Write-Output "sha256=$($hash.Hash.ToLowerInvariant())"
if ($markerPresent) {
    Write-Output "install_state=patched"
} else {
    Write-Output "install_state=unpatched"
}

if ($UpstreamRef) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "gh is required for --upstream-ref"
        exit 1
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "git is required for --upstream-ref"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) {
        Write-Error "Patch file not found: $PatchFile"
        exit 1
    }

    $apiPath = "repos/openai/codex/contents/$($targetPath)?ref=$UpstreamRef"
    $response = gh api $apiPath | ConvertFrom-Json
    $targetBlob = $response.sha
    $expectedBlobMatch = ($targetBlob -eq $ExpectedBlob).ToString().ToLowerInvariant()

    $tmpDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))
    try {
        $targetFile = Join-Path $tmpDir.FullName $targetPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetFile) | Out-Null
        $bytes = [Convert]::FromBase64String(($response.content -replace "\s", ""))
        [System.IO.File]::WriteAllBytes($targetFile, $bytes)

        Write-Output "upstream_repo=openai/codex"
        Write-Output "upstream_ref=$UpstreamRef"
        Write-Output "target_path=$targetPath"
        Write-Output "target_blob=$targetBlob"
        Write-Output "expected_blob=$ExpectedBlob"
        Write-Output "expected_blob_match=$expectedBlobMatch"
        Write-Output "patch_file=$PatchFile"

        Push-Location $tmpDir.FullName
        try {
            git apply --check $PatchFile
            if ($LASTEXITCODE -ne 0) {
                Write-Output "patch_apply=failed"
                Write-Output "compatibility=patch_rebase_required"
                exit $LASTEXITCODE
            }
        }
        finally {
            Pop-Location
        }

        Write-Output "patch_apply=ok"
        if ($expectedBlobMatch -eq "true") {
            Write-Output "compatibility=patch_applies"
        } else {
            Write-Output "compatibility=patch_applies_with_drift"
        }
    }
    finally {
        Remove-Item -LiteralPath $tmpDir.FullName -Recurse -Force
    }
}

if ($LogsDb -and (Get-Command sqlite3 -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $LogsDb)) {
    sqlite3 $LogsDb "select id, datetime(timestamp, 'unixepoch'), level, target, substr(feedback_log_body, 1, 240) from logs where target = 'codex_core::compact_remote' and feedback_log_body like '%fallback model%' order by id desc limit 20;"
}
