[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Package,
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [switch] $Standalone,
  [string] $PowerShellExecutable = (Get-Command pwsh).Source
)

$ErrorActionPreference = "Stop"
$script = Join-Path $RepositoryRoot "Tools\windows\package.ps1"
$testRoot = Join-Path $RepositoryRoot ".build\packaging-real-home-$PID"
if ($Standalone) {
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) "graphcode-setup-real-$PID"
}
$testHome = Join-Path $testRoot "深い & (空間)\用户"
$install = Join-Path $testHome "GraphCode\current"
$oldHome = $env:USERPROFILE
$oldAppData = $env:APPDATA
$oldPath = $env:PATH
$oldModulePath = $env:PSModulePath
$oldModuleCache = $env:PSModuleAnalysisCachePath
$oldSupport = $env:GRAPHCODE_SUPPORT_DIR
$oldUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pwsh = $PowerShellExecutable
function Invoke-Package([string] $command, [hashtable] $extra = @{}) {
  $args = @("-NoProfile", "-File", $script, "-Command", $command)
  foreach ($key in $extra.Keys) { $args += @("-$key", [string] $extra[$key]) }
  & $pwsh @args
  if ($LASTEXITCODE -ne 0) { throw "real lifecycle $command failed" }
}
try {
  New-Item -ItemType Directory -Force $testHome | Out-Null
  $env:PSModuleAnalysisCachePath = Join-Path $testHome "ModuleAnalysisCache"
  $env:USERPROFILE = $testHome
  $env:APPDATA = Join-Path $testHome "AppData\Roaming"
  $env:PSModulePath = $null
  $env:GRAPHCODE_SUPPORT_DIR = Join-Path $testHome ".graphcode"
  if ($Standalone) {
    $archive = Join-Path $testHome "release.zip"
    Copy-Item -LiteralPath $Package -Destination $archive
    $Package = $archive
    $incoming = Join-Path $testHome "incoming"
    Expand-Archive -LiteralPath $Package -DestinationPath $incoming
    $script = Join-Path $incoming "GraphCode\GraphCode-Setup.ps1"
    if (-not (Test-Path -LiteralPath $script)) { throw "Package has no standalone setup" }
    $env:PATH = Join-Path $env:SystemRoot "System32"
    Invoke-Package "Verify"
    Invoke-Package "Install" @{ InstallRoot = $install }
    $script = Join-Path $install "GraphCode-Setup.ps1"
    Remove-Item -LiteralPath $incoming -Recurse -Force
  } else {
    Invoke-Package "Install" @{ Package = $Package; InstallRoot = $install }
  }
  $bin = Join-Path $install "bin"
  $env:PATH = "$bin;$env:SystemRoot\System32"
  $env:GRAPHCODE_SUPPORT_DIR = Join-Path $testHome ".graphcode"
  $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  $identityBytes = [Text.Encoding]::UTF8.GetBytes("$sid|$([IO.Path]::GetFullPath($env:GRAPHCODE_SUPPORT_DIR).TrimEnd('\').ToLowerInvariant())")
  $identityHash = (([Security.Cryptography.SHA256]::Create().ComputeHash($identityBytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  $taskName = "GraphCode\graphcoded-$($identityHash.Substring(0, 32))"
  & (Join-Path $bin "graphcode.exe") projects
  if ($LASTEXITCODE -ne 0) { throw "scheduled daemon CLI reachability failed" }
  Set-Content (Join-Path $testHome ".graphcode\real-lifecycle.json") preserved -Force
  $expected = [IO.Path]::GetFullPath((Join-Path $bin "graphcoded.exe"))
  $beforeLockedUpgrade = @(Get-ChildItem -LiteralPath $install -File -Recurse -Force |
    Sort-Object FullName | Get-FileHash -Algorithm SHA256 | Select-Object Path, Hash) |
    ConvertTo-Json -Compress
  $lockedShell = [IO.File]::Open((Join-Path $bin "graphcode-windows.exe"),
    [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $lockedOutput = & $pwsh -NoProfile -File $script -Command Upgrade `
      -Package $Package -InstallRoot $install 2>&1 | Out-String
    $lockedExit = $LASTEXITCODE
  } finally {
    $lockedShell.Dispose()
  }
  $afterLockedUpgrade = @(Get-ChildItem -LiteralPath $install -File -Recurse -Force |
    Sort-Object FullName | Get-FileHash -Algorithm SHA256 | Select-Object Path, Hash) |
    ConvertTo-Json -Compress
  if ($lockedExit -eq 0 -or $lockedOutput -notmatch "access|used|denied" -or
      $beforeLockedUpgrade -cne $afterLockedUpgrade) {
    throw "locked upgrade did not preserve the complete prior installation: $lockedOutput"
  }
  & (Join-Path $bin "graphcode.exe") projects
  if ($LASTEXITCODE -ne 0) { throw "locked upgrade did not restart the unchanged daemon" }
  if (@(Get-ChildItem -LiteralPath (Split-Path $install -Parent) -Directory -Filter ".GraphCode-*").Count) {
    throw "locked upgrade left transaction debris after preserving the installation"
  }
  Invoke-Package "Upgrade" @{ Package = $Package; InstallRoot = $install }
  $running = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ($running.Count -ne 1) { throw "upgrade did not restart exactly one installed daemon" }
  $badReach = Join-Path $testHome "bad-reachability"
  Expand-Archive $Package -DestinationPath $badReach
  $badDaemon = Join-Path $badReach "GraphCode\bin\graphcoded.exe"
  Set-Content $badDaemon "not an executable"
  $manifestPath = Join-Path $badReach "GraphCode\manifest.json"
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $entry = @($manifest.files | Where-Object path -eq "bin/graphcoded.exe")[0]
  $entry.size = (Get-Item $badDaemon).Length
  $entry.sha256 = (Get-FileHash $badDaemon -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
  $priorDaemonHash = (Get-FileHash (Join-Path $bin "graphcoded.exe")).Hash
  & $pwsh -NoProfile -File $script -Command Upgrade `
    -Package (Join-Path $badReach "GraphCode") -InstallRoot $install
  if ($LASTEXITCODE -eq 0) { throw "daemon reachability failure was accepted" }
  $restoredDaemonHash = (Get-FileHash (Join-Path $bin "graphcoded.exe")).Hash
  $restored = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ($priorDaemonHash -ne $restoredDaemonHash -or $restored.Count -ne 1) {
    throw "daemon reachability failure did not restore and restart the prior installation"
  }
  $bad = Join-Path $testHome "bad-package"
  Expand-Archive $Package -DestinationPath $bad
  Add-Content (Join-Path $bad "GraphCode\bin\graphcode.exe") corrupt
  $before = (Get-FileHash (Join-Path $bin "graphcode.exe")).Hash
  & $pwsh -NoProfile -File $script -Command Upgrade `
    -Package (Join-Path $bad "GraphCode") -InstallRoot $install
  $failure = $LASTEXITCODE
  $after = (Get-FileHash (Join-Path $bin "graphcode.exe")).Hash
  if ($failure -eq 0 -or $before -ne $after) { throw "failed upgrade did not preserve the prior installation" }
  Invoke-Package "Uninstall" @{ InstallRoot = $install; RemoveUserData = $true }
  $left = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ((Test-Path $install) -or (Test-Path (Join-Path $testHome ".graphcode")) -or $left.Count -ne 0) {
    throw "uninstall left installed state, support data, or daemon process"
  }
  if (schtasks.exe /Query /TN $taskName 2>$null) {
    throw "uninstall left the GraphCode daemon task"
  }
  Write-Output "Real scheduled-task install/locked-upgrade/upgrade/rollback/uninstall: PASS"
  if ($Standalone) { Write-Output "Standalone extracted/installed setup lifecycle using $pwsh`: PASS" }
} finally {
  $env:USERPROFILE = $oldHome
  $env:APPDATA = $oldAppData
  $env:PATH = $oldPath
  $env:PSModulePath = $oldModulePath
  $env:PSModuleAnalysisCachePath = $oldModuleCache
  $env:GRAPHCODE_SUPPORT_DIR = $oldSupport
  [Environment]::SetEnvironmentVariable("Path", $oldUserPath, "User")
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
