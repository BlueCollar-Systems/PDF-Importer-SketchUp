# Launch one SketchUp probe under the shared executable-host leases.
param(
  [Parameter(Mandatory = $true)][string]$Script,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [Parameter(Mandatory = $true)][hashtable]$EnvVars,
  [int]$TimeoutSeconds = 600,
  [string]$Claimant = 'Codex /root/sketchup_report_lane',
  [string]$ResourceBoardPath = $env:BCS_RESOURCE_BOARD_PATH,
  [string]$LeaseRoot = 'C:\TMP'
)

$globalLockPath = Join-Path $LeaseRoot 'CAD-HOST-GLOBAL.lock'
$hostLockPath = Join-Path $LeaseRoot 'SKETCHUP-HOST.lock'
$globalLock = $null
$hostLock = $null
$spawnedPid = $null
$prior = $null
$preferenceChanged = $false

function Acquire-HostLock([string]$Path, [string]$Kind) {
  try {
    $handle = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $payload = @{
      claimant = $Claimant
      kind = $Kind
      pid = $PID
      acquired_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $handle.Write($bytes, 0, $bytes.Length)
    $handle.Flush()
    return $handle
  } catch [System.IO.IOException] {
    throw "REFUSING: $Kind host lease already exists at $Path"
  }
}

if ([string]::IsNullOrWhiteSpace($ResourceBoardPath)) {
  throw 'REFUSING: supply -ResourceBoardPath or BCS_RESOURCE_BOARD_PATH'
}
if (!(Test-Path -LiteralPath $ResourceBoardPath -PathType Leaf)) {
  throw "REFUSING: RESOURCE_BOARD.md is missing: $ResourceBoardPath"
}
$boardText = Get-Content -LiteralPath $ResourceBoardPath -Raw
if (($boardText -notmatch [regex]::Escape($Claimant)) -or
    ($boardText -notmatch '(?i)SketchUp')) {
  throw "REFUSING: RESOURCE_BOARD.md does not contain this SketchUp claimant"
}

try {
  $globalLock = Acquire-HostLock $globalLockPath 'global executable'
  $hostLock = Acquire-HostLock $hostLockPath 'SketchUp'

  $running = (Get-Process -Name SketchUp -ErrorAction SilentlyContinue |
    Measure-Object).Count
  if ($running -gt 0) {
    throw "REFUSING: $running SketchUp process(es) already running."
  }

  foreach ($keyName in $EnvVars.Keys) {
    Set-Item -Path ('Env:' + $keyName) -Value $EnvVars[$keyName]
  }
  if (Test-Path -LiteralPath $OutFile) {
    Clear-Content -LiteralPath $OutFile
  }

  $registryKey = 'HKCU:\Software\SketchUp\SketchUp 2017\PREFS'
  $preferenceName = 'RubyManager_DisablePlugins'
  $prior = (Get-ItemProperty -Path $registryKey -Name $preferenceName `
    -ErrorAction SilentlyContinue).$preferenceName
  New-ItemProperty -Path $registryKey -Name $preferenceName -Value 1 `
    -PropertyType DWord -Force | Out-Null
  $preferenceChanged = $true

  $process = Start-Process `
    -FilePath 'C:\Program Files\SketchUp\SketchUp 2017\SketchUp.exe' `
    -ArgumentList '-RubyStartup', $Script -PassThru
  $spawnedPid = $process.Id
  Add-Type -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);' `
    -Name NMP -Namespace BcProbe -ErrorAction SilentlyContinue
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $active = Get-Process -Id $spawnedPid -ErrorAction SilentlyContinue
    if ($null -eq $active) { break }
    if ($active.MainWindowTitle -ceq 'Welcome to SketchUp') {
      $window = $active.MainWindowHandle
      if ($window -ne [IntPtr]::Zero) {
        [BcProbe.NMP]::PostMessage(
          $window, 0x0100, [IntPtr]0x0D, [IntPtr]::Zero
        ) | Out-Null
        [BcProbe.NMP]::PostMessage(
          $window, 0x0101, [IntPtr]0x0D, [IntPtr]::Zero
        ) | Out-Null
      }
    }
    if ((Test-Path -LiteralPath $OutFile) -and
        ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
      Start-Sleep -Seconds 2
      break
    }
    Start-Sleep -Milliseconds 500
  }
} finally {
  if ($null -ne $spawnedPid) {
    Get-Process -Id $spawnedPid -ErrorAction SilentlyContinue |
      ForEach-Object { Stop-Process -Id $spawnedPid -Force }
  }
  if ($preferenceChanged) {
    if ($null -eq $prior) {
      Remove-ItemProperty -Path $registryKey -Name $preferenceName `
        -ErrorAction SilentlyContinue
    } else {
      New-ItemProperty -Path $registryKey -Name $preferenceName -Value $prior `
        -PropertyType DWord -Force | Out-Null
    }
  }
  if ($null -ne $hostLock) { $hostLock.Dispose() }
  if ($null -ne $globalLock) { $globalLock.Dispose() }
  if ($null -ne $hostLock) {
    Remove-Item -LiteralPath $hostLockPath -Force -ErrorAction SilentlyContinue
  }
  if ($null -ne $globalLock) {
    Remove-Item -LiteralPath $globalLockPath -Force -ErrorAction SilentlyContinue
  }
}

if ((Test-Path -LiteralPath $OutFile) -and
    ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
  Write-Output ('OK: {0:N0} bytes' -f (Get-Item -LiteralPath $OutFile).Length)
} else {
  Write-Output 'NO OUTPUT'
  exit 1
}
