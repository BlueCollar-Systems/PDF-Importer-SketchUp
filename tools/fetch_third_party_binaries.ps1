# fetch_third_party_binaries.ps1
# Download Windows Poppler utilities into the SketchUp extension bundled bin folder.
# Run from repo root before building the .rbz release.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\tools\fetch_third_party_binaries.ps1
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$BinDir = Join-Path $RepoRoot 'extracted\sketchup_ext\bc_pdf_vector_importer\bin'
$TempDir = Join-Path $env:TEMP ('bc_poppler_fetch_' + [guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

Write-Host "Fetching Poppler Windows build..."
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/oschwartz10612/poppler-windows/releases/latest'
$asset = $release.assets | Where-Object { $_.name -match '^Release-.*\.zip$' } | Select-Object -First 1
if (-not $asset) {
    throw 'Could not find Poppler Release zip on latest GitHub release.'
}

$zipPath = Join-Path $TempDir $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
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

$required = @('pdftocairo.exe', 'pdftotext.exe', 'pdffonts.exe')
foreach ($name in $required) {
    $src = Join-Path $sourceBin $name
    if (-not (Test-Path $src)) {
        throw "Missing required Poppler tool: $name"
    }
    Copy-Item -Path $src -Destination (Join-Path $BinDir $name) -Force
    Write-Host "  + $name"
}

Get-ChildItem -Path $sourceBin -Filter '*.dll' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $BinDir $_.Name) -Force
    Write-Host "  + $($_.Name)"
}

$LicenseDir = Join-Path $BinDir 'licenses'
New-Item -ItemType Directory -Force -Path $LicenseDir | Out-Null
Get-ChildItem -Path $popplerRoot.FullName -Recurse -File |
    Where-Object { $_.Name -match '^(COPYING|COPYRIGHT|LICENSE|NOTICE|README|AUTHORS)' } |
    ForEach-Object {
        $relative = $_.FullName.Substring($popplerRoot.FullName.Length).TrimStart('\', '/')
        $safeName = $relative -replace '[\\/:*?"<>|]', '_'
        Copy-Item -Path $_.FullName -Destination (Join-Path $LicenseDir $safeName) -Force
        Write-Host "  + licenses\$safeName"
    }

@'
Bundled third-party tools for PDF Vector Importer (SketchUp)

Poppler utilities and supporting DLLs (distributed under their upstream
licenses; Poppler itself is GPL-family licensed, and the Windows bundle also
contains LGPL/MIT/BSD-style support libraries):
  pdftocairo.exe, pdftotext.exe, pdffonts.exe and required DLLs

Fetched by tools/fetch_third_party_binaries.ps1 from:
  https://github.com/oschwartz10612/poppler-windows/releases/latest

For exact license files, source links, and component versions, preserve this
notice plus the copied licenses/ folder with each published BlueCollar Systems
release.

MuPDF mutool is NOT bundled here (AGPL license review required).
Ghostscript is NOT bundled here (large installer; user one-click install documented).
'@ | Set-Content -Path (Join-Path $BinDir 'THIRD_PARTY_NOTICES.txt') -Encoding UTF8

Write-Host ""
Write-Host "Poppler tools copied to:"
Write-Host "  $BinDir"
Write-Host ""
Write-Host "Next: python build_release.py"

Remove-Item -Recurse -Force $TempDir
