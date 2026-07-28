# Reconstruct the exact extension-local Windows Poppler runtime.
# Nothing under the live extension is changed until source hashes, the exact
# manifest, and the Adobe-GB1 fixture smoke all pass in an isolated stage.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ContractScript = Join-Path $RepoRoot 'tools\poppler_runtime_contract.py'
$PruneScript = Join-Path $RepoRoot 'tools\prune_poppler_bundle.py'
$SmokeScript = Join-Path $RepoRoot 'tools\smoke_poppler_helpers.py'
$TemplateDir = Join-Path $RepoRoot 'tools\poppler_runtime_templates'
$LiveSupport = Join-Path $RepoRoot 'extracted\sketchup_ext\bc_pdf_vector_importer'
$TempDir = Join-Path $env:TEMP ('bc_poppler_fetch_' + [guid]::NewGuid().ToString('N'))
$StageSupport = Join-Path $TempDir 'stage\bc_pdf_vector_importer'

function Invoke-PythonChecked {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & python @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "python command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Assert-FileHash {
    param([string]$Path, [string]$Expected, [string]$Label)
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch: expected $Expected, got $Actual"
    }
}

$ContractJson = & python $ContractScript describe
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to load the shared Poppler runtime contract.'
}
$Contract = $ContractJson | ConvertFrom-Json

New-Item -ItemType Directory -Path $TempDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $StageSupport $Contract.bin) -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $StageSupport 'Library\licenses') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $StageSupport $Contract.data) -Force | Out-Null

try {
    Write-Host "Fetching pinned Poppler Windows asset $($Contract.asset)..."
    $Release = Invoke-RestMethod -Uri (
        'https://api.github.com/repos/oschwartz10612/poppler-windows/releases/tags/' +
        $Contract.release_tag
    )
    $Assets = @($Release.assets | Where-Object { $_.name -eq $Contract.asset })
    if ($Assets.Count -ne 1) {
        throw "Expected exactly one $($Contract.asset) asset; found $($Assets.Count)."
    }
    $WindowsZip = Join-Path $TempDir $Contract.asset
    Invoke-WebRequest -Uri $Assets[0].browser_download_url -OutFile $WindowsZip
    Assert-FileHash $WindowsZip $Contract.asset_sha256 'Poppler Windows asset'

    $WindowsExtract = Join-Path $TempDir 'windows'
    Expand-Archive -LiteralPath $WindowsZip -DestinationPath $WindowsExtract
    $WindowsRoot = Join-Path $WindowsExtract $Contract.archive_root
    $SourceBin = Join-Path $WindowsRoot 'Library\bin'
    if (-not (Test-Path -LiteralPath $SourceBin -PathType Container)) {
        throw "Pinned Windows archive root/layout is absent: $SourceBin"
    }

    foreach ($Helper in $Contract.helpers) {
        $Source = Join-Path $SourceBin $Helper
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            throw "Pinned Windows archive is missing required helper: $Helper"
        }
        Copy-Item -LiteralPath $Source -Destination (Join-Path $StageSupport $Contract.bin)
    }
    Get-ChildItem -LiteralPath $SourceBin -Filter '*.dll' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $StageSupport $Contract.bin)
    }

    Write-Host 'Pruning staged DLLs by PE import and delay-load reachability...'
    Invoke-PythonChecked $PruneScript --bin-dir (Join-Path $StageSupport $Contract.bin)

    Write-Host 'Fetching complete pinned poppler-data tree...'
    $DataArchive = Join-Path $TempDir 'poppler-data.tar.gz'
    Invoke-WebRequest -Uri $Contract.poppler_data_url -OutFile $DataArchive
    Assert-FileHash $DataArchive $Contract.poppler_data_archive_sha256 'poppler-data archive'
    $DataExtract = Join-Path $TempDir 'data'
    New-Item -ItemType Directory -Path $DataExtract | Out-Null
    & tar -xzf $DataArchive -C $DataExtract
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }
    $SourceData = Join-Path $DataExtract $Contract.poppler_data_root
    if (-not (Test-Path -LiteralPath $SourceData -PathType Container)) {
        throw "Pinned poppler-data archive root is absent: $SourceData"
    }
    Copy-Item -Path (Join-Path $SourceData '*') -Destination (
        Join-Path $StageSupport $Contract.data
    ) -Recurse

    Write-Host 'Fetching separately pinned official GPLv3 text...'
    $Gpl3 = Join-Path $TempDir 'GPL-3.0.txt'
    Invoke-WebRequest -Uri $Contract.gpl3_text_url -OutFile $Gpl3
    Assert-FileHash $Gpl3 $Contract.gpl3_text_sha256 'GPLv3 text'

    $Library = Join-Path $StageSupport 'Library'
    $Licenses = Join-Path $Library 'licenses'
    Copy-Item -LiteralPath (Join-Path $TemplateDir 'THIRD_PARTY_NOTICES.txt') -Destination (
        Join-Path $Library 'THIRD_PARTY_NOTICES.txt'
    )
    Copy-Item -LiteralPath (Join-Path $TemplateDir 'LICENSE_README.txt') -Destination (
        Join-Path $Licenses 'README.txt'
    )
    foreach ($Name in @('COPYING', 'COPYING.adobe', 'COPYING.gpl2', 'README')) {
        Copy-Item -LiteralPath (Join-Path $SourceData $Name) -Destination (
            Join-Path $Licenses ('share_poppler_' + $Name)
        )
    }
    Copy-Item -LiteralPath $Gpl3 -Destination (
        Join-Path $Licenses 'share_poppler_COPYING.gpl3'
    )

    Write-Host 'Writing and verifying the exact blocked runtime manifest...'
    Invoke-PythonChecked $ContractScript write-manifest --support-root $StageSupport --license-status blocked
    Invoke-PythonChecked $ContractScript verify --support-root $StageSupport

    Write-Host 'Running the Adobe-GB1 fixture smoke against the isolated stage...'
    Invoke-PythonChecked $SmokeScript --support-root $StageSupport --required

    Write-Host 'Promoting the verified stage transactionally...'
    Invoke-PythonChecked $ContractScript install --stage-support $StageSupport --live-support $LiveSupport
    Invoke-PythonChecked $ContractScript verify --support-root $LiveSupport

    Write-Host ''
    Write-Host "Verified Poppler runtime installed under $LiveSupport"
    Write-Host 'Publication remains blocked until qualified license_review approval.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        $ResolvedTemp = (Resolve-Path -LiteralPath $TempDir).Path
        $ResolvedParent = (Resolve-Path -LiteralPath $env:TEMP).Path
        if ([IO.Path]::GetDirectoryName($ResolvedTemp) -ne $ResolvedParent -or
            [IO.Path]::GetFileName($ResolvedTemp) -notlike 'bc_poppler_fetch_*') {
            throw "Refusing to clean unexpected fetch path: $ResolvedTemp"
        }
        Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
    }
}
