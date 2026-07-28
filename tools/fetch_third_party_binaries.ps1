# fetch_third_party_binaries.ps1
# Stage a free zero-ceremony Poppler runtime into the SketchUp extension:
#   Library/bin + share/poppler + licenses + notices
# Then prune DLLs, smoke helpers, and build the integrity manifest.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\tools\fetch_third_party_binaries.ps1
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

$ErrorActionPreference = 'Stop'

# Pin a known-good poppler-windows release tag (not releases/latest).
$PopplerReleaseTag = 'v26.02.0-0'
$PopplerAssetName = 'Release-26.02.0-0.zip'
$PopplerAssetSha256 = '993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SupportDir = Join-Path $RepoRoot 'extracted\sketchup_ext\bc_pdf_vector_importer'
$BinDir = Join-Path $SupportDir 'Library\bin'
$ShareDir = Join-Path $SupportDir 'share\poppler'
$LicenseDir = Join-Path $SupportDir 'Library\licenses'
$LegacyBin = Join-Path $SupportDir 'bin'
$TempDir = Join-Path $env:TEMP ('bc_poppler_fetch_' + [guid]::NewGuid().ToString('N'))

if (Test-Path $LegacyBin) {
    throw "Legacy direct bin/ must be removed before staging Library/bin: $LegacyBin"
}

New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

Write-Host "Fetching Poppler Windows build (pinned $PopplerReleaseTag)..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/oschwartz10612/poppler-windows/releases/tags/$PopplerReleaseTag"
$asset = $release.assets | Where-Object { $_.name -eq $PopplerAssetName } | Select-Object -First 1
if (-not $asset) {
    throw "Could not find exact Poppler asset $PopplerAssetName on pinned tag $PopplerReleaseTag."
}

$zipPath = Join-Path $TempDir $PopplerAssetName
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
$actualSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $PopplerAssetSha256) {
    throw "Poppler archive SHA256 mismatch: expected $PopplerAssetSha256, got $actualSha256"
}
Expand-Archive -Path $zipPath -DestinationPath $TempDir -Force

$popplerRoot = Get-ChildItem -Path $TempDir -Directory | Where-Object { $_.Name -match 'poppler' } | Select-Object -First 1
if (-not $popplerRoot) {
    throw 'Poppler archive did not contain an expected root folder.'
}

$sourceBin = Join-Path $popplerRoot.FullName 'Library\bin'
if (-not (Test-Path $sourceBin)) {
    $sourceBin = Join-Path $popplerRoot.FullName 'bin'
}
if (-not (Test-Path $sourceBin)) {
    throw "Could not locate Poppler bin folder under $($popplerRoot.FullName)"
}

$sourceShare = Join-Path $popplerRoot.FullName 'share\poppler'
if (-not (Test-Path $sourceShare)) {
    $sourceShare = Join-Path $popplerRoot.FullName 'Library\share\poppler'
}
if (-not (Test-Path $sourceShare)) {
    throw "Could not locate share/poppler under $($popplerRoot.FullName)"
}

foreach ($dir in @($BinDir, $ShareDir, $LicenseDir)) {
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$required = @('pdftocairo.exe', 'pdftotext.exe', 'pdffonts.exe')
foreach ($name in $required) {
    $src = Join-Path $sourceBin $name
    if (-not (Test-Path $src)) {
        throw "Missing required Poppler tool: $name"
    }
    Copy-Item -Path $src -Destination (Join-Path $BinDir $name) -Force
    Write-Host "  + Library\bin\$name"
}

Get-ChildItem -Path $sourceBin -Filter '*.dll' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $BinDir $_.Name) -Force
    Write-Host "  + Library\bin\$($_.Name)"
}

Write-Host "Copying Poppler data tree..."
Copy-Item -Path (Join-Path $sourceShare '*') -Destination $ShareDir -Recurse -Force
$requiredData = @(
    'cidToUnicode\Adobe-GB1',
    'cidToUnicode\Adobe-CNS1',
    'cidToUnicode\Adobe-Japan1',
    'cidToUnicode\Adobe-Korea1'
)
foreach ($rel in $requiredData) {
    $path = Join-Path $ShareDir $rel
    if (-not (Test-Path $path)) {
        throw "Missing required Poppler language data: $rel"
    }
}

Get-ChildItem -Path $popplerRoot.FullName -Recurse -File |
    Where-Object { $_.Name -match '^(COPYING|COPYRIGHT|LICENSE|NOTICE|README|AUTHORS)' } |
    ForEach-Object {
        $relative = $_.FullName.Substring($popplerRoot.FullName.Length).TrimStart('\', '/')
        $safeName = $relative -replace '[\\/:*?"<>|]', '_'
        Copy-Item -Path $_.FullName -Destination (Join-Path $LicenseDir $safeName) -Force
        Write-Host "  + Library\licenses\$safeName"
    }

@"
Bundled third-party tools for PDF Vector Importer (SketchUp)

Poppler utilities, PE-reachable DLLs, and share/poppler language data
(distributed under their upstream licenses; Poppler is GPL-family):
  pdftocairo.exe, pdftotext.exe, pdffonts.exe + required DLLs + cid maps

Fetched by tools/fetch_third_party_binaries.ps1 from pinned tag:
  https://github.com/oschwartz10612/poppler-windows/releases/tag/$PopplerReleaseTag

Canonical layout:
  Library/bin
  Library/licenses
  share/poppler

After fetch, tools/prune_poppler_bundle.py drops unused sibling DLLs.
The libcurl -> libssh2 -> libcrypto chain is retained because poppler.dll
imports it (hard PE IAT dependency).

MuPDF mutool is NOT bundled here (AGPL license review required).
Ghostscript is NOT bundled here (optional font-repair helper).

STABLE PUBLICATION IS BLOCKED until an independent qualified reviewer closes
the exact binary dependency/license record. Integrity pins are not approval.
"@ | Set-Content -Path (Join-Path $SupportDir 'Library\THIRD_PARTY_NOTICES.txt') -Encoding UTF8

Write-Host ""
Write-Host "Pruning unused Poppler DLLs (PE import + delay-load walk)..."
& python (Join-Path $RepoRoot 'tools\prune_poppler_bundle.py') --bin-dir $BinDir
if ($LASTEXITCODE -ne 0) {
    throw "prune_poppler_bundle.py failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Running post-prune Poppler helper smoke..."
& python (Join-Path $RepoRoot 'tools\smoke_poppler_helpers.py') --required
if ($LASTEXITCODE -ne 0) {
    throw "smoke_poppler_helpers.py failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Building poppler-runtime-manifest.json..."
& python (Join-Path $RepoRoot 'tools\build_poppler_runtime_manifest.py') --write --poppler-tag $PopplerReleaseTag
if ($LASTEXITCODE -ne 0) {
    throw "build_poppler_runtime_manifest.py failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Poppler runtime staged under:"
Write-Host "  $SupportDir"
Write-Host "  pinned tag: $PopplerReleaseTag"
Write-Host ""
Write-Host "Next: update PINNED_MEMBER_INVENTORY_SHA256 in dependency_resolver.rb,"
Write-Host "      then python build_release.py --require-poppler-smoke"

Remove-Item -Recurse -Force $TempDir
