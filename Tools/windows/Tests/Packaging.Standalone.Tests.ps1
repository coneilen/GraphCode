[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-standalone-$([guid]::NewGuid())"
$definitions = @{}
foreach ($file in @("package.ps1", "PackageRuntime.ps1")) {
  $path = Join-Path $repoRoot "Tools\windows\$file"
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Packaging parse errors: $errors" }
  foreach ($node in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
      }, $true)) {
    $definitions[$node.Name] = $node.Extent.Text
  }
}
foreach ($name in @("Fail", "Require", "Get-Manifest", "Write-Metadata", "Write-PackageSetup")) {
  if (-not $definitions.ContainsKey($name)) { throw "RED: standalone setup helper is missing: $name" }
  . ([scriptblock]::Create($definitions[$name]))
}

function Invoke-Setup(
  [string] $hostPath, [string[]] $arguments, [string] $expectedError,
  [string] $entryPoint = $setup, [string] $successMarker = "Package verification: PASS"
) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $hostPath
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.WorkingDirectory = $fixture
  $start.Environment["PATH"] = Join-Path $env:SystemRoot "System32"
  $start.Environment["PSModuleAnalysisCachePath"] = Join-Path $fixture "ModuleAnalysisCache"
  [void] $start.Environment.Remove("PSModulePath")
  foreach ($variable in @($start.Environment.Keys | Where-Object { $_ -like "GRAPHCODE_*" -or $_ -like "SWIFT*" -or $_ -like "ZIG*" })) {
    [void] $start.Environment.Remove($variable)
  }
  foreach ($argument in @("-NoProfile", "-NonInteractive", "-File", $entryPoint) + $arguments) {
    [void] $start.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    if (-not $process.Start()) { throw "Could not start standalone setup host" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) {
      $process.Kill($true)
      throw "Standalone setup timed out"
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($expectedError) {
      if ($process.ExitCode -eq 0 -or $output -notmatch [regex]::Escape($expectedError)) {
        throw "Standalone rejection was not specific ($expectedError): $output"
      }
    } elseif ($process.ExitCode -ne 0 -or $output -notmatch [regex]::Escape($successMarker)) {
      throw "Standalone verification failed with $hostPath`: $output"
    }
  } finally { $process.Dispose() }
}

try {
  $root = Join-Path $fixture "extracted package\GraphCode"
  New-Item -ItemType Directory -Path (Join-Path $root "bin"), (Join-Path $root "licenses"), (Join-Path $root "assets") -Force | Out-Null
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe", "zmx.exe", "swiftCore.dll")) {
    Set-Content (Join-Path $root "bin\$name") "verification-only fixture"
  }
  foreach ($name in @("LICENSE", "THIRD-PARTY-NOTICES.txt", "licenses\WINGHOSTTY-LICENSE.txt",
      "licenses\ZMX-LICENSE.txt", "assets\winghostty-win32-host.lib")) {
    Set-Content (Join-Path $root $name) "fixture"
  }
  Copy-Item (Join-Path $shellRoot "provider-pins.json") (Join-Path $root "provider-pins.json")
  $pins = Get-Content (Join-Path $root "provider-pins.json") -Raw | ConvertFrom-Json
  $provenance = @{ schemaVersion = 1 }
  foreach ($provider in @("winghostty", "zmx")) {
    $artifact = if ($provider -eq "winghostty") { "assets/winghostty-win32-host.lib" } else { "bin/zmx.exe" }
    $license = "licenses/$($provider.ToUpperInvariant())-LICENSE.txt"
    $provenance[$provider] = @{
      repository = $pins.$provider.repository
      sha = $pins.$provider.sha
      packagePath = $artifact
      sha256 = (Get-FileHash (Join-Path $root $artifact)).Hash
      licensePath = $license
      licenseSha256 = (Get-FileHash (Join-Path $root $license)).Hash
    }
  }
  $provenance | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "provider-provenance.json") -Encoding utf8
  Write-PackageSetup $root
  Write-Metadata $root "1.2.3"
  @{ schemaVersion = 1; files = @(Get-Manifest $root) } |
    ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "manifest.json") -Encoding utf8
  $setup = Join-Path $root "GraphCode-Setup.ps1"
  $setupSource = Get-Content -LiteralPath $setup -Raw
  if ($setupSource -match '\$repoRoot|\$shellRoot|# GRAPHCODE_PACKAGE_RUNTIME|function Build-Package') {
    throw "Standalone setup retains build/repository dependencies"
  }
  $runtime = Get-Content (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1") -Raw
  if (-not $setupSource.Contains($runtime.Trim())) { throw "Setup does not embed the shared lifecycle verbatim" }
  $zip = Join-Path $fixture "GraphCode.zip"
  [IO.Compression.ZipFile]::CreateFromDirectory($root, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
  $nativeProbe = Join-Path $fixture "native-command.ps1"
  $nativeSource = (@("Fail", "Invoke-PackageCommand") | ForEach-Object { $definitions[$_] }) -join "`n"
  $nativeSource += @'

$ErrorActionPreference = "Stop"
$global:LASTEXITCODE = 41
$result = Invoke-PackageCommand (Join-Path $env:SystemRoot "System32\cmd.exe") @("/d", "/c", "echo expected-native-error 1>&2 & exit /b 7")
if ($result.ExitCode -ne 7 -or $result.Output -notmatch "expected-native-error") {
  throw "Native failure lost its exit code or stderr"
}
if ($ErrorActionPreference -ne "Stop") { throw "Native capture changed caller error policy" }
if ($global:LASTEXITCODE -ne 41) { throw "Native capture changed caller exit status" }
$global:LASTEXITCODE = 0
Write-Output "Native command exit/stderr preservation: PASS"
'@
  [IO.File]::WriteAllText($nativeProbe, $nativeSource, [Text.UTF8Encoding]::new($true))
  foreach ($hostPath in @((Get-Command powershell.exe).Source, (Get-Command pwsh).Source)) {
    Invoke-Setup $hostPath @() ""
    Invoke-Setup $hostPath @("-Command", "Verify", "-Package", $zip) ""
    Invoke-Setup $hostPath @("-Command", "Verify", "-TrustedSignerThumbprint", ("A" * 40)) "trusted publisher verification requires a signed package"
    Invoke-Setup $hostPath @("-Command", "Build") "Cannot validate argument"
    Invoke-Setup $hostPath @() "" $nativeProbe "Native command exit/stderr preservation: PASS"
  }
  Add-Content (Join-Path $root "bin\swiftCore.dll") "tamper"
  Invoke-Setup (Get-Command powershell.exe).Source @("-Command", "Verify") "size mismatch"
  Write-Output "Standalone setup without repository/toolchains on Windows PowerShell 5.1 and PowerShell 7: PASS"
} finally {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
