[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "Dev tooling tests require Windows." }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$scriptPath = Join-Path $repoRoot "Tools\windows\dev.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "Windows development entrypoint is missing: $scriptPath"
}

. $scriptPath

function Assert-True([bool] $condition, [string] $message) {
  if (-not $condition) { throw $message }
}

function Read-FixtureEvidence([string] $path) {
  $result = @{}
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $separator = $line.IndexOf("=")
    if ($separator -lt 1) { throw "Malformed fixture evidence: $line" }
    $result[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
  }
  return $result
}

function Write-FixtureExecutable([string] $path) {
  $source = @'
using System;
using System.IO;
using System.Threading;

public static class DevFixture {
  public static int Main() {
    string role = Environment.GetEnvironmentVariable("GRAPHCODE_DEV_ROLE") ?? "unknown";
    string support = Environment.GetEnvironmentVariable("GRAPHCODE_SUPPORT_DIR");
    string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
    string temp = Environment.GetEnvironmentVariable("TEMP");
    string output = Path.Combine(temp, role + ".txt");
    Directory.CreateDirectory(temp);
    File.WriteAllLines(output, new [] {
      "role=" + role,
      "support=" + support,
      "localAppData=" + local,
      "temp=" + temp,
      "tmp=" + Environment.GetEnvironmentVariable("TMP"),
      "runId=" + Environment.GetEnvironmentVariable("GRAPHCODE_DEV_RUN_ID"),
      "secretExistedAtLaunch=" + File.Exists(Path.Combine(support ?? "", ".graphcode-rendezvous.secret")),
      "startedUtcTicks=" + DateTime.UtcNow.Ticks
    });
    if (role == "daemon") {
      Thread.Sleep(150);
      File.WriteAllText(Path.Combine(support, ".graphcode-rendezvous.secret"), "fixture-created");
    }
    Thread.Sleep(TimeSpan.FromMinutes(5));
    return 0;
  }
}
'@
  $sourcePath = [IO.Path]::ChangeExtension($path, ".cs")
  [IO.File]::WriteAllText($sourcePath, $source)
  $compiler = Get-ChildItem (Join-Path $env:WINDIR "Microsoft.NET\Framework64") `
    -Recurse -Filter csc.exe -ErrorAction Stop |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  & $compiler /nologo /target:exe "/out:$path" $sourcePath
  if ($LASTEXITCODE -ne 0) { throw "Fixture executable compilation failed" }
}

$fixtureRoot = Join-Path $repoRoot ".build\windows\dev-tests\$([guid]::NewGuid().ToString('N'))"
$layoutRoot = Join-Path $fixtureRoot "layout"
$sourceRoot = Join-Path $fixtureRoot "sources"
$executed = 0

try {
  New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
  $swiftRoot = Join-Path $sourceRoot "swift"
  $shellRoot = Join-Path $sourceRoot "shell"
  $providerRoot = Join-Path $sourceRoot "provider"
  foreach ($directory in @($swiftRoot, $shellRoot, $providerRoot)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  foreach ($name in @("graphcoded.exe", "graphcode.exe", "swiftCore.dll")) {
    Set-Content -LiteralPath (Join-Path $swiftRoot $name) -Value $name
  }
  Set-Content -LiteralPath (Join-Path $shellRoot "graphcode-windows.exe") -Value "shell"
  Set-Content -LiteralPath (Join-Path $providerRoot "zmx.exe") -Value "zmx"

  $layout = Publish-DevLayout -LayoutRoot $layoutRoot -SwiftRoot $swiftRoot `
    -ShellExecutable (Join-Path $shellRoot "graphcode-windows.exe") `
    -ZmxExecutable (Join-Path $providerRoot "zmx.exe")
  foreach ($name in @("graphcoded.exe", "graphcode.exe", "graphcode-windows.exe", "zmx.exe", "swiftCore.dll")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $layout.Bin $name) -PathType Leaf) `
      "Runnable layout is missing $name"
  }
  $executed++

  Remove-Item -LiteralPath (Join-Path $layoutRoot "bin") -Recurse -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $layoutRoot "bin") | Out-Null
  $fixtureExe = Join-Path $fixtureRoot "dev-fixture.exe"
  Write-FixtureExecutable $fixtureExe
  foreach ($name in @("graphcoded.exe", "graphcode-windows.exe")) {
    Copy-Item -LiteralPath $fixtureExe -Destination (Join-Path $layoutRoot "bin\$name")
  }
  Set-Content -LiteralPath (Join-Path $layoutRoot "bin\graphcode.exe") -Value "cli"
  Set-Content -LiteralPath (Join-Path $layoutRoot "bin\zmx.exe") -Value "zmx"

  $state = Start-DevRun -RepoRoot $repoRoot -LayoutRoot $layoutRoot -StartupTimeoutSeconds 10
  Assert-True ($state.processes.Count -eq 2) "Run state did not capture daemon and shell identities"
  foreach ($role in @("daemon", "shell")) {
    $evidencePath = Join-Path $state.sandbox.temp "$role.txt"
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $evidencePath) -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $evidencePath) "$role did not report its environment"
    $evidence = Read-FixtureEvidence $evidencePath
    Assert-True ($evidence.support -eq $state.sandbox.support) "$role support root was not owned"
    Assert-True ($evidence.localAppData -eq $state.sandbox.localAppData) "$role LOCALAPPDATA was not owned"
    Assert-True ($evidence.temp -eq $state.sandbox.temp -and $evidence.tmp -eq $state.sandbox.temp) `
      "$role TEMP/TMP roots were not owned"
    $expectedSecret = $role -eq "shell"
    Assert-True ([bool]::Parse($evidence.secretExistedAtLaunch) -eq $expectedSecret) `
      "$role rendezvous evidence did not prove daemon-created startup state"
  }
  Stop-DevRun -RepoRoot $repoRoot -LayoutRoot $layoutRoot
  foreach ($identity in $state.processes) {
    Assert-True (-not (Get-Process -Id $identity.pid -ErrorAction SilentlyContinue)) `
      "Stop left the captured $($identity.role) process running"
  }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $layoutRoot "run.json"))) `
    "Successful stop left an active run record"
  $executed++

  $identitySupport = Join-Path $fixtureRoot "identity-support"
  $identityTemp = Join-Path $fixtureRoot "identity-temp"
  New-Item -ItemType Directory -Force -Path $identitySupport,$identityTemp | Out-Null
  $identityProcess = Start-DevProcess -Executable (Join-Path $layoutRoot "bin\graphcoded.exe") `
    -Role "identity" -WorkingDirectory (Join-Path $layoutRoot "bin") -Environment @{
      GRAPHCODE_SUPPORT_DIR = $identitySupport
      TEMP = $identityTemp
      TMP = $identityTemp
    }
  try {
    $identityProcess.Refresh()
    $mismatched = [ordered]@{
      schemaVersion = 1
      runId = [guid]::NewGuid().ToString()
      repoRoot = $repoRoot
      layoutRoot = $layoutRoot
      sessionPrefix = "gcdev-identity"
      sandbox = $null
      processes = @([ordered]@{
          role = "daemon"
          pid = $identityProcess.Id
          executablePath = (Join-Path $layoutRoot "bin\graphcoded.exe")
          startTimeUtcTicks = $identityProcess.StartTime.ToUniversalTime().Ticks + 1
        })
    }
    $mismatched | ConvertTo-Json -Depth 6 |
      Set-Content -LiteralPath (Join-Path $layoutRoot "run.json") -Encoding utf8
    $rejected = $false
    try {
      Stop-DevRun -RepoRoot $repoRoot -LayoutRoot $layoutRoot
    } catch {
      $rejected = $_.Exception.Message -like "*creation time does not match*"
    }
    Assert-True $rejected "Stop did not report the captured creation identity mismatch"
    Assert-True (-not $identityProcess.HasExited) `
      "Stop terminated a process whose captured creation identity did not match"
    Assert-True (Test-Path -LiteralPath (Join-Path $layoutRoot "run.json")) `
      "Stop discarded the run record after an identity mismatch"
  } finally {
    if (-not $identityProcess.HasExited) { Stop-Process -Id $identityProcess.Id -Force }
  }
  $executed++
} finally {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ExecutablePath -and
      $_.ExecutablePath.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($executed -le 0) { throw "Dev tooling tests reported no executed cases." }
Write-Output "Dev.Tests.ps1: PASS; executed=$executed"
