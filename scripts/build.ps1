param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [string]$PatchFile,
    [string]$OutDir,
    [string]$CargoArgs = "build -p codex-cli --bin codex --release"
)

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $PatchFile) {
    $PatchFile = Join-Path $RepoRoot "patches/openai-codex-compact-fallback.patch"
}
if (-not $OutDir) {
    $OutDir = Join-Path $RepoRoot "dist/windows"
}

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Write-Error "Source directory not found: $SourceDir"
    exit 1
}
if (-not (Test-Path -LiteralPath $PatchFile -PathType Leaf)) {
    Write-Error "Patch file not found: $PatchFile"
    exit 1
}

$CargoDir = $SourceDir
if (-not (Test-Path -LiteralPath (Join-Path $CargoDir "Cargo.toml") -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $SourceDir "codex-rs/Cargo.toml") -PathType Leaf)) {
    $CargoDir = Join-Path $SourceDir "codex-rs"
}
if (-not (Test-Path -LiteralPath (Join-Path $CargoDir "Cargo.toml") -PathType Leaf)) {
    Write-Error "Cargo.toml not found in $SourceDir or $(Join-Path $SourceDir 'codex-rs')"
    exit 1
}

Push-Location $SourceDir
try {
    git apply --check $PatchFile
    git apply $PatchFile
}
finally {
    Pop-Location
}

Push-Location $CargoDir
try {
    $cargoParts = $CargoArgs -split " "
    & cargo @cargoParts
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item -LiteralPath (Join-Path $CargoDir "target/release/codex.exe") -Destination (Join-Path $OutDir "codex.exe") -Force
Write-Output "built=$(Join-Path $OutDir 'codex.exe')"
