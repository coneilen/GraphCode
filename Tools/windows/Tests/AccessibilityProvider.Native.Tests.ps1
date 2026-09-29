[CmdletBinding()]
param([string] $VcVars)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
if (-not $VcVars) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio vswhere is required" }
  $installation = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $installation) { throw "Visual C++ build tools are required" }
  $VcVars = Join-Path $installation "VC\Auxiliary\Build\vcvars64.bat"
}
if (-not (Test-Path -LiteralPath $VcVars)) { throw "Missing Visual C++ setup: $VcVars" }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("graphcode-uia-native-" + [guid]::NewGuid())
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedPath = $env:PATH
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $env:TEMP = $scratch
  $env:TMP = $scratch
  $installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
  if (Test-Path -LiteralPath $installer) { $env:PATH = "$installer;$savedPath" }
  Push-Location $scratch
  try {
    $test = Join-Path $PSScriptRoot "AccessibilityProvider.Native.Tests.cpp"
    $provider = Join-Path $repoRoot "graphcode-windows\src\AccessibilityProvider.cpp"
    $command = 'call "' + $VcVars + '" >nul && cl /nologo /EHsc /std:c++17 ' +
      '/Fe:uia-native.exe "' + $test + '" "' + $provider + '" ' +
      'oleaut32.lib uiautomationcore.lib user32.lib && .\uia-native.exe'
    & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) { throw "Native accessibility provider tests failed: $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
} finally {
  $env:TEMP = $savedTemp
  $env:TMP = $savedTmp
  $env:PATH = $savedPath
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
