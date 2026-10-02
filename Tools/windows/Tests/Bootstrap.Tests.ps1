[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$bootstrapPath = Join-Path $repoRoot "Tools\windows\bootstrap.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $bootstrapPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Bootstrap script has parse errors: $errors" }
foreach ($name in @("Test-BootstrapPathBudget", "Install-Provider")) {
  $definition = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
  if ($definition) {
    . ([scriptblock]::Create($definition.Extent.Text))
  } elseif ($name -eq "Test-BootstrapPathBudget") {
    function Test-BootstrapPathBudget {}
  } else {
    throw "Bootstrap helper is missing: $name"
  }
}

Describe "Windows bootstrap provider setup" {
  BeforeEach {
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) (
      "graphcode-bootstrap-" + [guid]::NewGuid().ToString("N"))
    $script:ProviderRoot = Join-Path $script:fixture "providers"
    [void][IO.Directory]::CreateDirectory($script:ProviderRoot)
    $script:gitCalls = [Collections.Generic.List[string]]::new()
    $script:statusOutput = @()
    $script:failNextCheckout = $false
    function script:git {
      $arguments = @($args | ForEach-Object { [string] $_ })
      $script:gitCalls.Add(($arguments -join [char]31))
      $global:LASTEXITCODE = 0
      if ($arguments -contains "clone") {
        [void][IO.Directory]::CreateDirectory(
          (Join-Path $arguments[-1] ".git"))
      }
      if ($arguments -contains "checkout" -and $script:failNextCheckout) {
        $script:failNextCheckout = $false
        $global:LASTEXITCODE = 1
        return
      }
      if ($arguments -contains "checkout" -and $arguments -contains "--force") {
        $script:statusOutput = @()
      }
      if ($arguments -contains "status") {
        return $script:statusOutput
      }
    }
    $script:pin = [pscustomobject]@{
      remoteUrl = "https://example.invalid/provider.git"
      sha = "0123456789012345678901234567890123456789"
    }
  }

  AfterEach {
    Remove-Item -LiteralPath $script:fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\git -ErrorAction SilentlyContinue
  }

  It "enables long paths for provider Git operations and persists local config" {
    $destination = Install-Provider $script:pin "winghostty"
    $separator = [char]31
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "clone", "--no-checkout",
          $script:pin.remoteUrl, $destination) -join $separator)) | Should Be $true
    ($script:gitCalls -contains (
        @("-C", $destination, "config", "--local", "core.longpaths", "true") -join $separator)) |
      Should Be $true
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "fetch", "--quiet",
          "origin", $script:pin.sha) -join $separator)) | Should Be $true
    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "checkout", "--quiet",
          "--detach", $script:pin.sha) -join $separator)) | Should Be $true
    Test-Path -LiteralPath (Join-Path $destination ".git\graphcode-bootstrap-checkout") |
      Should Be $false
  }

  It "recovers a bootstrap-owned partial provider checkout" {
    $destination = Join-Path $script:ProviderRoot "winghostty"
    $marker = Join-Path $destination ".git\graphcode-bootstrap-checkout"
    $script:failNextCheckout = $true
    { Install-Provider $script:pin "winghostty" } |
      Should Throw "Checking out winghostty pin $($script:pin.sha) failed"
    Test-Path -LiteralPath $marker -PathType Leaf | Should Be $true
    $script:statusOutput = @(" D missing-long-path-corpus")

    Install-Provider $script:pin "winghostty" | Should Be $destination

    ($script:gitCalls -contains (
        @("-c", "core.longpaths=true", "-C", $destination, "checkout", "--force",
          "--quiet", "--detach", $script:pin.sha) -join [char]31)) | Should Be $true
    Test-Path -LiteralPath $marker | Should Be $false
  }

  It "does not overwrite an unmarked dirty provider checkout" {
    $destination = Join-Path $script:ProviderRoot "winghostty"
    [void][IO.Directory]::CreateDirectory((Join-Path $destination ".git"))
    $script:statusOutput = @(" M contributor-change")

    { Install-Provider $script:pin "winghostty" } |
      Should Throw "winghostty provider checkout is dirty: $destination"
    @($script:gitCalls | Where-Object { $_ -match ([char]31 + "checkout" + [char]31) }).Count |
      Should Be 0
  }

  It "warns when pinned provider or worktree fixtures exceed the legacy path budget" {
    $warnings = [Collections.Generic.List[string]]::new()
    $deepRoot = "C:\" + ("deep\" * 30) + "GraphCode"
    $deepProviders = Join-Path $deepRoot ".graphcode-tools\providers"

    Test-BootstrapPathBudget $deepRoot $deepProviders {
      param($message)
      $warnings.Add($message)
    }

    $warnings.Count | Should Be 1
    $warnings[0] | Should Match "legacy MAX_PATH"
    $warnings[0] | Should Match ([regex]::Escape("C:\src\GraphCode"))
    $warnings[0] | Should Match ([regex]::Escape("-ProviderRoot C:\gc-providers"))
  }

  It "does not warn for a short checkout and provider root" {
    $warnings = [Collections.Generic.List[string]]::new()
    Test-BootstrapPathBudget "C:\src\GraphCode" "C:\gc-providers" {
      param($message)
      $warnings.Add($message)
    }
    $warnings.Count | Should Be 0
  }
}
