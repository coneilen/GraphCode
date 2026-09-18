[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
. (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1")
$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-scheduler-$([guid]::NewGuid())"
$oldSupport = $env:GRAPHCODE_SUPPORT_DIR
$env:GRAPHCODE_SUPPORT_DIR = $fixture
$InstallRoot = Join-Path $fixture "current"
$identity = Get-TaskIdentity $fixture
$scheduler = New-Object -ComObject Schedule.Service
$folder = $null
$definition = $null
$registered = $null
$action = $null
try {
  $scheduler.Connect()
  $definition = $scheduler.NewTask(0)
  $definition.Principal.UserId = $identity.sid
  $definition.Principal.LogonType = 3
  $definition.Settings.Enabled = $true
  $action = $definition.Actions.Create(0)
  $action.Path = Join-Path $env:SystemRoot "System32\cmd.exe"
  $action.Arguments = "/d /c exit 0"
  $rootFolder = $scheduler.GetFolder("\")
  try {
    try { $folder = $scheduler.GetFolder("\GraphCode") } catch {
      $failure = $_.Exception
      while ($failure.InnerException) { $failure = $failure.InnerException }
      if ($failure.HResult -notin @(-2147024894, -2147024893)) { throw }
      $folder = $rootFolder.CreateFolder("GraphCode")
    }
    $registered = $folder.RegisterTaskDefinition($identity.name.Split("\")[-1], $definition, 2, $identity.sid, $null, 3)
  } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($rootFolder) }
  if ($registered.State -ne 3) { throw "Scheduler fixture is not idle/ready" }
  if (-not (Test-DaemonTask $identity.name)) { throw "Existing idle task was reported absent" }
  $missingName = "graphcode-missing-$([guid]::NewGuid())"
  $missingError = $null
  try { [void] $folder.GetTask($missingName) } catch {
    $missingError = $_.Exception
    while ($missingError.InnerException) { $missingError = $missingError.InnerException }
  }
  if (-not $missingError -or $missingError.HResult -ne -2147024894) {
    throw "Missing task did not produce ERROR_FILE_NOT_FOUND: $missingError"
  }
  if (Test-DaemonTask "GraphCode\$missingName") { throw "Missing task was reported present" }
  $ended = Invoke-PackageCommand "schtasks.exe" @("/End", "/TN", $identity.name)
  if ($ended.ExitCode -ne 0) { throw "Ending an idle task failed: $($ended.Output)" }
  Stop-InstalledDaemon
  Remove-DaemonTask
  if (Test-DaemonTask $identity.name) { throw "Idle task was not removed" }
  Write-Output "Native missing-task HRESULT 0x80070002 and idle-task stop/delete: PASS"
} finally {
  try {
    if (Test-DaemonTask $identity.name) {
      $deleted = Invoke-PackageCommand "schtasks.exe" @("/Delete", "/TN", $identity.name, "/F")
      if ($deleted.ExitCode -ne 0) { throw "Could not remove owned scheduler fixture: $($deleted.Output)" }
    }
  } finally {
    $env:GRAPHCODE_SUPPORT_DIR = $oldSupport
    foreach ($value in @($registered, $action, $definition, $folder, $scheduler)) {
      if ($null -ne $value) { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($value) }
    }
  }
}
