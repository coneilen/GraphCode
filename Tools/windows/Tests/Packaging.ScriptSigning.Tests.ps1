[CmdletBinding()]
param([string] $SignToolPath)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
. (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1")
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $repoRoot "Tools\windows\package.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Package build script has parse errors: $errors" }
foreach ($name in @("Sign-PackageFile", "Write-PackageSetup")) {
  $definition = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
  if (-not $definition) { throw "Missing package signing helper: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}
if (-not $SignToolPath) {
  $SignToolPath = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
  if (-not $SignToolPath) {
    $SignToolPath = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin\*\x64\signtool.exe") -File |
      Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
  }
}
if (-not $SignToolPath -or -not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) {
  throw "The native script-signing contract requires Windows SDK signtool.exe"
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-script-signing-$([guid]::NewGuid())"
$key = $null
$certificate = $null
try {
  New-Item -ItemType Directory -Path $fixture | Out-Null
  Write-PackageSetup $fixture
  $scriptPath = Join-Path $fixture "GraphCode-Setup.ps1"
  $key = [Security.Cryptography.RSA]::Create(2048)
  $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
    "CN=GraphCode untrusted signing fixture", $key,
    [Security.Cryptography.HashAlgorithmName]::SHA256,
    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $usages = [Security.Cryptography.OidCollection]::new()
  [void] $usages.Add([Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.3"))
  $request.CertificateExtensions.Add(
    [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
  $request.CertificateExtensions.Add(
    [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
      [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
  $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
  $password = [guid]::NewGuid().ToString("N")
  $pfx = Join-Path $fixture "ephemeral.pfx"
  [IO.File]::WriteAllBytes($pfx, $certificate.Export(
      [Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
  $SignCertificate = $certificate.Thumbprint
  $SignTimestampUrl = $null
  function Invoke-EphemeralSigner {
    if ($args[0] -ne "sign" -or $args[1] -ne "/sha1" -or $args[2] -ne $SignCertificate) {
      throw "Production signer certificate arguments changed"
    }
    # Use a temporary PFX instead of installing a certificate in a user store.
    $arguments = @("sign", "/f", $pfx, "/p", $password) + $args[3..($args.Count - 1)]
    & $SignToolPath @arguments
  }
  Sign-PackageFile "Invoke-EphemeralSigner" $scriptPath
  $source = Get-Content -LiteralPath $scriptPath -Raw
  if ($source -notmatch '# SIG # Begin signature block') { throw "SignTool did not emit a PowerShell signature block" }
  $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -FilePath $scriptPath
  if ($signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint -or
      $signature.SignatureType -ne "Authenticode" -or
      $signature.Status -in @("NotSigned", "HashMismatch", "Valid")) {
    throw "PowerShell did not recognize the intentionally untrusted script signature: $($signature.Status)"
  }
  [void] [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Signing corrupted setup syntax: $errors" }
  $tampered = $source.Replace('$versionWasProvided = [bool]$Version', '$versionWasProvided = $false')
  if ($tampered -ceq $source) { throw "Script tamper fixture did not modify signed code" }
  [IO.File]::WriteAllText($scriptPath, $tampered, [Text.UTF8Encoding]::new($true))
  $tamperedSignature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -FilePath $scriptPath
  if ($tamperedSignature.Status -ne "HashMismatch") {
    throw "Native script signature did not detect code tampering: $($tamperedSignature.Status)"
  }
  Write-Output "Native SignTool PowerShell signature block and tamper detection (untrusted ephemeral certificate): PASS"
} finally {
  if ($certificate) { $certificate.Dispose() }
  if ($key) { $key.Dispose() }
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
