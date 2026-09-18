#requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet("Verify", "Install", "Upgrade", "Uninstall")]
  [string] $Command = "Verify",
  [string] $Package,
  [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA "GraphCode\current"),
  [string] $Version,
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string] $TrustedSignerThumbprint,
  [switch] $KeepUserData,
  [switch] $RemoveUserData,
  [switch] $NoScheduledTask
)

$ErrorActionPreference = "Stop"
if (-not $Package) { $Package = $PSScriptRoot }
$versionWasProvided = [bool]$Version
# Repository commands supply canonical pins; standalone follows the selected package.
$ProviderPinsPath = $null
$required = @("graphcoded.exe", "graphcode.exe", "zmx.exe")
$SignToolPath = $null

# GRAPHCODE_PACKAGE_RUNTIME

switch ($Command) {
  "Verify" {
    try {
      $root = Open-Package $Package
      Verify-PackageContents $root | Out-Null
      Write-Output "Package verification: PASS"
    } finally { Close-Package }
  }
  "Install" { Install-Package $false }
  "Upgrade" { Install-Package $true }
  "Uninstall" { Uninstall-Package }
}
