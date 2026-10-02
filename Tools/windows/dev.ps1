<#
.SYNOPSIS
  Builds, launches, and stops a checkout-scoped GraphCode Windows development run.

.DESCRIPTION
  This is a fast contributor entrypoint, not a validation gate. -Build uses the
  pinned bootstrap environment and the repository's provider, Swift staging,
  and Zig build mechanisms to assemble .build\windows\dev\bin. -Run starts the
  production daemon before the shell with fresh owned support/profile/temp
  roots unless -RealProfile is explicit. -Stop revalidates the captured process
  path and creation identity before terminating anything.
#>
[CmdletBinding()]
param(
  [switch] $Build,
  [switch] $Run,
  [switch] $Stop,
  [switch] $RealProfile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-NormalizedPath([string] $Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Test-PathInside([string] $Path, [string] $Root) {
  $candidate = Get-NormalizedPath $Path
  $rootPath = Get-NormalizedPath $Root
  return $candidate.StartsWith(
    $rootPath + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
  )
}

function Invoke-DevNative([string] $Description, [scriptblock] $Command) {
  Write-Host "==> $Description"
  $global:LASTEXITCODE = 0
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE"
  }
}

function Assert-DevArtifact([string] $Path, [string] $Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label is missing: $Path"
  }
}

function Publish-DevLayout(
  [Parameter(Mandatory)][string] $LayoutRoot,
  [Parameter(Mandatory)][string] $SwiftRoot,
  [Parameter(Mandatory)][string] $ShellExecutable,
  [Parameter(Mandatory)][string] $ZmxExecutable
) {
  $layout = Get-NormalizedPath $LayoutRoot
  $swift = Get-NormalizedPath $SwiftRoot
  $shell = Get-NormalizedPath $ShellExecutable
  $zmx = Get-NormalizedPath $ZmxExecutable
  foreach ($artifact in @(
      @{ Path = (Join-Path $swift "graphcoded.exe"); Label = "Swift daemon" },
      @{ Path = (Join-Path $swift "graphcode.exe"); Label = "Swift CLI" },
      @{ Path = $shell; Label = "Windows shell" },
      @{ Path = $zmx; Label = "zmx provider" }
    )) {
    Assert-DevArtifact $artifact.Path $artifact.Label
  }

  New-Item -ItemType Directory -Force -Path $layout | Out-Null
  if (Test-Path -LiteralPath (Join-Path $layout "run.json") -PathType Leaf) {
    throw "A development run record exists; stop it before replacing the runnable layout."
  }

  $staging = Join-Path $layout ".bin-staging-$([guid]::NewGuid().ToString('N'))"
  $previous = Join-Path $layout ".bin-previous-$([guid]::NewGuid().ToString('N'))"
  $bin = Join-Path $layout "bin"
  try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    Get-ChildItem -LiteralPath $swift -File |
      Copy-Item -Destination $staging -Force
    Copy-Item -LiteralPath $shell -Destination (Join-Path $staging "graphcode-windows.exe") -Force
    Copy-Item -LiteralPath $zmx -Destination (Join-Path $staging "zmx.exe") -Force
    foreach ($name in @("graphcoded.exe", "graphcode.exe", "graphcode-windows.exe", "zmx.exe")) {
      Assert-DevArtifact (Join-Path $staging $name) "Runnable layout artifact"
    }

    if (Test-Path -LiteralPath $bin) {
      [IO.Directory]::Move($bin, $previous)
    }
    [IO.Directory]::Move($staging, $bin)
    if (Test-Path -LiteralPath $previous) {
      Remove-Item -LiteralPath $previous -Recurse -Force
    }
  } catch {
    if (-not (Test-Path -LiteralPath $bin) -and (Test-Path -LiteralPath $previous)) {
      [IO.Directory]::Move($previous, $bin)
    }
    throw
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue
  }

  return [pscustomobject]@{
    Root = $layout
    Bin = $bin
    Daemon = Join-Path $bin "graphcoded.exe"
    Cli = Join-Path $bin "graphcode.exe"
    Shell = Join-Path $bin "graphcode-windows.exe"
    Zmx = Join-Path $bin "zmx.exe"
  }
}

function Initialize-DevToolEnvironment([string] $RepoRoot) {
  $environmentScript = Join-Path $RepoRoot ".graphcode-tools\environment.ps1"
  if (-not (Test-Path -LiteralPath $environmentScript -PathType Leaf)) {
    Write-Host "Pinned tool environment is absent; running Tools\windows\bootstrap.ps1."
    $global:LASTEXITCODE = 0
    & (Join-Path $RepoRoot "Tools\windows\bootstrap.ps1")
    if ($LASTEXITCODE -ne 0) {
      throw "Windows bootstrap failed with exit code $LASTEXITCODE"
    }
  }
  if (-not (Test-Path -LiteralPath $environmentScript -PathType Leaf)) {
    throw "Windows bootstrap did not produce $environmentScript"
  }
  . $environmentScript
  foreach ($name in @(
      "GRAPHCODE_SWIFT633",
      "GRAPHCODE_ZIG0152",
      "GRAPHCODE_ZIG0160",
      "GRAPHCODE_WINGHOSTTY_ROOT",
      "GRAPHCODE_ZMX_ROOT"
    )) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value -or -not (Test-Path -LiteralPath $value)) {
      throw "Pinned environment variable $name is missing or invalid; rerun Tools\windows\bootstrap.ps1"
    }
  }
}

function Build-DevLayout([string] $RepoRoot, [string] $LayoutRoot) {
  Initialize-DevToolEnvironment $RepoRoot
  $tools = Join-Path $RepoRoot "Tools\windows"
  $shellRoot = Join-Path $RepoRoot "graphcode-windows"
  $swiftStage = Join-Path $RepoRoot ".build\windows\release"
  $winghostty = $env:GRAPHCODE_WINGHOSTTY_ROOT
  $zmx = $env:GRAPHCODE_ZMX_ROOT
  $zig0152 = $env:GRAPHCODE_ZIG0152
  $zig0160 = $env:GRAPHCODE_ZIG0160

  Invoke-DevNative "Pinned provider artifacts" {
    & (Join-Path $tools "provider-build.ps1") -WinghosttyRoot $winghostty -ZmxRoot $zmx `
      -Zig0152 $zig0152 -Zig0160 $zig0160
  }
  Invoke-DevNative "Swift daemon and CLI release staging" {
    & (Join-Path $tools "stage-swift-products.ps1") -SwiftExecutable $env:GRAPHCODE_SWIFT633 `
      -Destination $swiftStage
  }

  $manifest = Get-Content -LiteralPath (Join-Path $shellRoot "build.zig.zon") -Raw
  if ($manifest -notmatch '(?m)\.version\s*=\s*"([^"]+)"') {
    throw "GraphCode Windows shell package version is missing"
  }
  $version = $Matches[1]
  Invoke-DevNative "GraphCode Windows shell ReleaseSafe build" {
    Push-Location $shellRoot
    try {
      & $zig0152 build `
        "-Dwinghostty-dir=$winghostty" `
        "-Dwinghostty-lib=$(Join-Path $winghostty 'zig-out\lib\winghostty-win32-host.lib')" `
        "-Dversion=$version" `
        -Doptimize=ReleaseSafe
    } finally {
      Pop-Location
    }
  }

  return Publish-DevLayout -LayoutRoot $LayoutRoot -SwiftRoot $swiftStage `
    -ShellExecutable (Join-Path $shellRoot "zig-out\bin\graphcode-windows.exe") `
    -ZmxExecutable (Join-Path $zmx "zig-out\bin\zmx.exe")
}

function Get-DevLayout([string] $LayoutRoot, [switch] $RequireArtifacts) {
  $bin = Join-Path (Get-NormalizedPath $LayoutRoot) "bin"
  $layout = [pscustomobject]@{
    Root = Get-NormalizedPath $LayoutRoot
    Bin = $bin
    Daemon = Join-Path $bin "graphcoded.exe"
    Cli = Join-Path $bin "graphcode.exe"
    Shell = Join-Path $bin "graphcode-windows.exe"
    Zmx = Join-Path $bin "zmx.exe"
  }
  if ($RequireArtifacts) {
    foreach ($entry in @(
        @{ Path = $layout.Daemon; Label = "Daemon" },
        @{ Path = $layout.Cli; Label = "CLI" },
        @{ Path = $layout.Shell; Label = "Shell" },
        @{ Path = $layout.Zmx; Label = "zmx" }
      )) {
      Assert-DevArtifact $entry.Path $entry.Label
    }
  }
  return $layout
}

function Get-DevProcessIdentity(
  [Parameter(Mandatory)][Diagnostics.Process] $Process,
  [Parameter(Mandatory)][string] $Role,
  [Parameter(Mandatory)][string] $ExecutablePath
) {
  $Process.Refresh()
  return [ordered]@{
    role = $Role
    pid = $Process.Id
    executablePath = Get-NormalizedPath $ExecutablePath
    startTimeUtcTicks = $Process.StartTime.ToUniversalTime().Ticks
  }
}

function Write-DevRunState([string] $Path, [object] $State) {
  $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
  try {
    $State | ConvertTo-Json -Depth 8 |
      Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function Start-DevProcess(
  [string] $Executable,
  [string] $Role,
  [string] $WorkingDirectory,
  [Collections.IDictionary] $Environment
) {
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $Executable
  $info.WorkingDirectory = $WorkingDirectory
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $Role -eq "daemon"
  foreach ($entry in $Environment.GetEnumerator()) {
    $info.Environment[[string] $entry.Key] = [string] $entry.Value
  }
  $info.Environment["GRAPHCODE_DEV_ROLE"] = $Role
  $process = [Diagnostics.Process]::Start($info)
  if (-not $process) { throw "Could not start GraphCode $Role process" }
  [void] $process.Handle
  return $process
}

function Test-DevIdentity([object] $Identity) {
  $process = Get-Process -Id ([int] $Identity.pid) -ErrorAction SilentlyContinue
  if (-not $process) {
    return [pscustomobject]@{ Status = "absent"; Process = $null; Message = $null }
  }
  $process.Refresh()
  $actualPath = try { Get-NormalizedPath $process.Path } catch { $null }
  $actualTicks = try { $process.StartTime.ToUniversalTime().Ticks } catch { $null }
  if (-not $actualPath -or $actualPath -ine (Get-NormalizedPath $Identity.executablePath)) {
    return [pscustomobject]@{
      Status = "mismatch"
      Process = $process
      Message = "PID $($Identity.pid) executable path does not match captured $($Identity.role) identity"
    }
  }
  if ($actualTicks -ne [int64] $Identity.startTimeUtcTicks) {
    return [pscustomobject]@{
      Status = "mismatch"
      Process = $process
      Message = "PID $($Identity.pid) creation time does not match captured $($Identity.role) identity"
    }
  }
  return [pscustomobject]@{ Status = "match"; Process = $process; Message = $null }
}

function Get-DevZmxIdentities([object] $State, [object] $Layout) {
  $identities = @()
  foreach ($candidate in @(Get-CimInstance Win32_Process -Filter "Name = 'zmx.exe'" -ErrorAction SilentlyContinue)) {
    if (-not $candidate.ExecutablePath -or -not $candidate.CommandLine) { continue }
    if ((Get-NormalizedPath $candidate.ExecutablePath) -ine (Get-NormalizedPath $Layout.Zmx)) { continue }
    if ($candidate.CommandLine -notlike "*$($State.sessionPrefix)*") { continue }
    $process = Get-Process -Id ([int] $candidate.ProcessId) -ErrorAction SilentlyContinue
    if ($process) {
      $identities += Get-DevProcessIdentity -Process $process -Role "zmx" -ExecutablePath $Layout.Zmx
    }
  }
  return $identities
}

function Stop-DevRun([string] $RepoRoot, [string] $LayoutRoot) {
  $repo = Get-NormalizedPath $RepoRoot
  $layout = Get-DevLayout $LayoutRoot
  $statePath = Join-Path $layout.Root "run.json"
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "No checkout-owned development run is recorded."
    return
  }

  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ($state.schemaVersion -ne 1) { throw "Unsupported development run state schema" }
  if ((Get-NormalizedPath $state.repoRoot) -ine $repo) {
    throw "Run state belongs to another checkout: $($state.repoRoot)"
  }
  if ((Get-NormalizedPath $state.layoutRoot) -ine $layout.Root) {
    throw "Run state belongs to another layout: $($state.layoutRoot)"
  }

  $expected = @{
    daemon = $layout.Daemon
    shell = $layout.Shell
    zmx = $layout.Zmx
  }
  $identities = @($state.processes)
  $identities += @(Get-DevZmxIdentities -State $state -Layout $layout)
  foreach ($identity in $identities) {
    if (-not $expected.ContainsKey([string] $identity.role)) {
      throw "Run state contains unsupported process role: $($identity.role)"
    }
    if ((Get-NormalizedPath $identity.executablePath) -ine
      (Get-NormalizedPath $expected[[string] $identity.role])) {
      throw "Run state $($identity.role) executable is outside the checkout layout"
    }
    if (-not (Test-PathInside $identity.executablePath $layout.Root)) {
      throw "Run state executable is not checkout-owned: $($identity.executablePath)"
    }
  }

  $mismatches = [Collections.Generic.List[string]]::new()
  foreach ($role in @("shell", "zmx", "daemon")) {
    foreach ($identity in @($identities | Where-Object role -eq $role)) {
      $verified = Test-DevIdentity $identity
      if ($verified.Status -eq "mismatch") {
        $mismatches.Add($verified.Message)
        continue
      }
      if ($verified.Status -eq "match") {
        try {
          $verified.Process.Kill()
          [void] $verified.Process.WaitForExit(5000)
        } catch [InvalidOperationException] {
          # The held process identity exited before termination; never reacquire by PID.
        }
        $after = Test-DevIdentity $identity
        if ($after.Status -eq "match") {
          $mismatches.Add("Captured $role process $($identity.pid) did not stop")
        }
      }
    }
  }
  if ($mismatches.Count -gt 0) {
    throw "Development stop refused incomplete or mismatched identities: $($mismatches -join '; ')"
  }
  Remove-Item -LiteralPath $statePath -Force
  Write-Host "Stopped checkout-owned development run $($state.runId)."
}

function Start-DevRun(
  [string] $RepoRoot,
  [string] $LayoutRoot,
  [switch] $RealProfile,
  [ValidateRange(1, 120)][int] $StartupTimeoutSeconds = 15
) {
  $repo = Get-NormalizedPath $RepoRoot
  $layout = Get-DevLayout $LayoutRoot -RequireArtifacts
  $statePath = Join-Path $layout.Root "run.json"
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    throw "A development run record already exists. Use -Stop before launching another run."
  }

  $runId = [guid]::NewGuid().ToString("N")
  $sessionPrefix = "gcdev-$runId"
  $sandbox = $null
  if (-not $RealProfile) {
    $runRoot = Join-Path $layout.Root "runs\$runId"
    $sandbox = [ordered]@{
      root = $runRoot
      support = Join-Path $runRoot "support"
      localAppData = Join-Path $runRoot "localappdata"
      temp = Join-Path $runRoot "temp"
    }
    foreach ($directory in @($sandbox.support, $sandbox.localAppData, $sandbox.temp)) {
      New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
  }

  $environment = [ordered]@{
    GRAPHCODE_ZMX = $layout.Zmx
    GRAPHCODE_DEV_RUN_ID = $runId
    GRAPHCODE_SHELL_SESSION_PREFIX = $sessionPrefix
  }
  if ($sandbox) {
    $environment.GRAPHCODE_SUPPORT_DIR = $sandbox.support
    $environment.LOCALAPPDATA = $sandbox.localAppData
    $environment.TEMP = $sandbox.temp
    $environment.TMP = $sandbox.temp
  }
  $state = [ordered]@{
    schemaVersion = 1
    runId = $runId
    repoRoot = $repo
    layoutRoot = $layout.Root
    createdUtc = [DateTime]::UtcNow.ToString("O")
    realProfile = [bool] $RealProfile
    sessionPrefix = $sessionPrefix
    sandbox = $sandbox
    processes = @()
  }

  try {
    $daemon = Start-DevProcess -Executable $layout.Daemon -Role "daemon" `
      -WorkingDirectory $layout.Bin -Environment $environment
    $state.processes += Get-DevProcessIdentity -Process $daemon -Role "daemon" `
      -ExecutablePath $layout.Daemon
    Write-DevRunState $statePath $state

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline) {
      if ($daemon.HasExited) {
        throw "GraphCode daemon exited before the shell launch with code $($daemon.ExitCode)"
      }
      if ($RealProfile) {
        Start-Sleep -Milliseconds 500
        $ready = -not $daemon.HasExited
        break
      }
      if (Test-Path -LiteralPath (Join-Path $sandbox.support ".graphcode-rendezvous.secret") -PathType Leaf) {
        $ready = $true
        break
      }
      Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
      throw "GraphCode daemon did not create its rendezvous secret within $StartupTimeoutSeconds seconds"
    }

    $shell = Start-DevProcess -Executable $layout.Shell -Role "shell" `
      -WorkingDirectory $layout.Bin -Environment $environment
    $state.processes += Get-DevProcessIdentity -Process $shell -Role "shell" `
      -ExecutablePath $layout.Shell
    Write-DevRunState $statePath $state
    Start-Sleep -Milliseconds 500
    if ($shell.HasExited) {
      throw "GraphCode shell exited during startup with code $($shell.ExitCode)"
    }
    Write-Host "Launched checkout-owned development run $runId."
    return [pscustomobject] $state
  } catch {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
      try { Stop-DevRun -RepoRoot $repo -LayoutRoot $layout.Root } catch {
        Write-Warning "Automatic cleanup failed: $($_.Exception.Message)"
      }
    }
    throw
  }
}

function Write-DevLayoutReport([object] $Layout) {
  Write-Host "LAYOUT_ROOT=$($Layout.Root)"
  Write-Host "DAEMON_ARTIFACT=$($Layout.Daemon)"
  Write-Host "CLI_ARTIFACT=$($Layout.Cli)"
  Write-Host "SHELL_ARTIFACT=$($Layout.Shell)"
  Write-Host "ZMX_ARTIFACT=$($Layout.Zmx)"
}

if ($MyInvocation.InvocationName -eq ".") { return }
if (-not ($Build -or $Run -or $Stop)) {
  throw "Choose at least one action: -Build, -Run, or -Stop."
}
if ($RealProfile -and -not $Run) {
  throw "-RealProfile is only valid with -Run."
}
if (-not $IsWindows) { throw "Tools\windows\dev.ps1 requires Windows." }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$layoutRoot = Join-Path $repoRoot ".build\windows\dev"
$buildStatus = "NOT_REQUESTED"
$launchStatus = "NOT_REQUESTED"

if ($Stop) {
  Stop-DevRun -RepoRoot $repoRoot -LayoutRoot $layoutRoot
}
if ($Build) {
  $layout = Build-DevLayout -RepoRoot $repoRoot -LayoutRoot $layoutRoot
  $buildStatus = "BUILT"
  Write-DevLayoutReport $layout
}
if ($Run) {
  $layout = Get-DevLayout $layoutRoot -RequireArtifacts
  $state = Start-DevRun -RepoRoot $repoRoot -LayoutRoot $layoutRoot -RealProfile:$RealProfile
  $launchStatus = "LAUNCHED runId=$($state.runId)"
  Write-DevLayoutReport $layout
  if ($state.sandbox) {
    Write-Host "SUPPORT_ROOT=$($state.sandbox.support)"
    Write-Host "LOCALAPPDATA_ROOT=$($state.sandbox.localAppData)"
    Write-Host "TEMP_ROOT=$($state.sandbox.temp)"
  } else {
    Write-Warning "Real profile mode is active; GraphCode profile roots were inherited."
  }
}

Write-Host "BUILD_STATUS=$buildStatus"
Write-Host "LAUNCH_STATUS=$launchStatus"
Write-Host "VALIDATION_STATUS=NOT_RUN; use Tools\windows\validate.ps1 for contributor and CI validation"
