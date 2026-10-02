[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $DaemonExecutable,
  [Parameter(Mandatory)]
  [string] $ScratchRoot
)

$ErrorActionPreference = "Stop"
$DaemonExecutable = (Resolve-Path -LiteralPath $DaemonExecutable).Path
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
if (-not (Test-Path -LiteralPath $DaemonExecutable -PathType Leaf)) {
  throw "real graphcoded.exe is missing: $DaemonExecutable"
}

$nonce = [guid]::NewGuid().ToString("N")
$runRoot = Join-Path $ScratchRoot "redirected-userprofile-$nonce"
$redirectedProfile = Join-Path $runRoot "profile"
$supportDirectory = Join-Path $runRoot "support"
$tempDirectory = Join-Path $runRoot "temp"
$evidenceDirectory = Join-Path $ScratchRoot "redirected-userprofile-evidence"
$shutdownEventName = "Local\GraphCode-redirected-userprofile-$PID-$nonce"
$shutdownEvent = $null
$process = $null
$stdoutTask = $null
$stderrTask = $null
$successful = $false

function Format-ExitCode([int] $code) {
  $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$code), 0)
  return "0x{0:X8}" -f $unsigned
}

New-Item -ItemType Directory -Force -Path @(
    $runRoot,
    $redirectedProfile,
    $supportDirectory,
    $tempDirectory,
    $evidenceDirectory
  ) | Out-Null

try {
  $shutdownEvent = [Threading.EventWaitHandle]::new(
    $false,
    [Threading.EventResetMode]::ManualReset,
    $shutdownEventName
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $DaemonExecutable
  $startInfo.WorkingDirectory = Split-Path -Parent $DaemonExecutable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($name in @(
      "GRAPHCODE_SOCKET",
      "GRAPHCODE_DAEMON_PIPE",
      "GRAPHCODE_DAEMON_STARTUP_EVENT",
      "GRAPHCODE_DAEMON_HANDOFF_READY_EVENT",
      "GRAPHCODE_DAEMON_HANDOFF_TEST_STATE")) {
    [void] $startInfo.Environment.Remove($name)
  }
  $startInfo.Environment["USERPROFILE"] = $redirectedProfile
  $startInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $supportDirectory
  $startInfo.Environment["TEMP"] = $tempDirectory
  $startInfo.Environment["TMP"] = $tempDirectory
  $startInfo.Environment["GRAPHCODE_DAEMON_SHUTDOWN_EVENT"] = $shutdownEventName

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "could not start graphcoded.exe"
  }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()

  if ($process.WaitForExit(3000)) {
    $process.Refresh()
    throw (
      "graphcoded.exe exited with $(Format-ExitCode $process.ExitCode) under redirected " +
      "USERPROFILE; stdout='$($stdoutTask.Result.Trim())'; " +
      "stderr='$($stderrTask.Result.Trim())'")
  }

  [void] $shutdownEvent.Set()
  if (-not $process.WaitForExit(10000)) {
    throw "graphcoded.exe ignored its owned shutdown event"
  }
  $process.Refresh()
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  if ($process.ExitCode -ne 0) {
    throw "graphcoded.exe shutdown returned $(Format-ExitCode $process.ExitCode)"
  }
  if ($stdout -notmatch "graphcoded: listening on namedPipe") {
    throw "graphcoded.exe did not report a listening endpoint: $stdout"
  }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    throw "graphcoded.exe wrote unexpected stderr: $stderr"
  }
  if (-not (Test-Path -LiteralPath (
        Join-Path $supportDirectory ".graphcode-rendezvous.secret") -PathType Leaf)) {
    throw "graphcoded.exe did not initialize the explicit support directory"
  }
  if (@(Get-ChildItem -LiteralPath $redirectedProfile -Force).Count -ne 0) {
    throw "graphcoded.exe wrote into redirected USERPROFILE despite explicit support isolation"
  }

  $summary = @(
    "REDIRECTED_USERPROFILE_DAEMON: PASS"
    "executable=$DaemonExecutable"
    "support=$supportDirectory"
    "profile=$redirectedProfile"
    "exit=$(Format-ExitCode $process.ExitCode)"
    "stdout=$($stdout.Trim())"
    "stderr=$($stderr.Trim())"
  )
  $evidencePath = Join-Path $evidenceDirectory "redirected-userprofile-$nonce.txt"
  [IO.File]::WriteAllLines($evidencePath, $summary, [Text.UTF8Encoding]::new($false))
  $summary
  "evidence=$evidencePath"
  $successful = $true
} finally {
  if ($process -and -not $process.HasExited) {
    if ($shutdownEvent) {
      [void] $shutdownEvent.Set()
      [void] $process.WaitForExit(3000)
    }
    if (-not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      [void] $process.WaitForExit(3000)
    }
  }
  if ($process) {
    $process.Dispose()
  }
  if ($shutdownEvent) {
    $shutdownEvent.Dispose()
  }
  if ($successful) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  } else {
    Write-Output "Failure artifacts retained at $runRoot"
  }
}
