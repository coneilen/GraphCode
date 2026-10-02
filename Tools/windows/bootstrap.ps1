[CmdletBinding()]
param(
  [string] $ToolRoot,
  [string] $ProviderRoot,
  [switch] $SkipSwift
)

$ErrorActionPreference = "Stop"
# Progress rendering dominates Invoke-WebRequest and Expand-Archive on hosted
# runners (about two minutes for the two Zig archives); it carries no evidence.
$ProgressPreference = "SilentlyContinue"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not $ToolRoot) {
  $ToolRoot = Join-Path $repoRoot ".graphcode-tools"
}
if (-not $ProviderRoot) {
  $ProviderRoot = Join-Path $ToolRoot "providers"
}
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$ProviderRoot = [IO.Path]::GetFullPath($ProviderRoot)

function Test-BootstrapPathBudget(
    [string] $RepositoryRoot,
    [string] $Providers,
    [scriptblock] $WarningSink
  ) {
  $legacyMaxPath = 259
  $providerProbe = Join-Path (Join-Path $Providers "winghostty") (
    "test\fuzz-libghostty\corpus\parser-cmin\" +
    "id_000213,time_0,execs_0,orig_id_001278,src_001266,time_20982," +
    "execs_1128131,op_quick,pos_31,val_+2,+cov")
  $worktreeProbe = Join-Path $RepositoryRoot (
    "graphcode-windows\.zig-cache\" +
    "worktree-process-00000000000000000000000000000000\" +
    "removal-output-selected-00000000000000000000000000000000\" +
    "outside\.git\objects")
  $overBudget = @($providerProbe, $worktreeProbe |
      Where-Object { $_.Length -gt $legacyMaxPath })
  if ($overBudget.Count -eq 0) {
    return
  }

  $lengths = $overBudget | ForEach-Object { $_.Length }
  $message = (
    "GraphCode Windows bootstrap path budget warning: projected paths reach " +
    "$($lengths -join ', ') characters, above legacy MAX_PATH " +
    "($legacyMaxPath). Use a short checkout such as C:\src\GraphCode and, " +
    "when needed, pass -ToolRoot C:\gc-tools -ProviderRoot C:\gc-providers. " +
    "Provider Git operations enable repository-local core.longpaths=true, " +
    "but other Windows tools and tests can still fail at this depth.")
  if ($WarningSink) {
    & $WarningSink $message
  } else {
    Write-Warning $message -WarningAction Continue
  }
}

Test-BootstrapPathBudget $repoRoot $ProviderRoot
New-Item -ItemType Directory -Force $ToolRoot, $ProviderRoot | Out-Null

function Install-Zig([string] $Version, [string] $Sha256) {
  $destination = Join-Path $ToolRoot "zig-$Version"
  $executable = Join-Path $destination "zig.exe"
  if (Test-Path -LiteralPath $executable -PathType Leaf) {
    $installedVersion = & $executable version
    if ($LASTEXITCODE -eq 0 -and $installedVersion -eq $Version) {
      return $executable
    }
    throw "Existing Zig installation is not version ${Version}: $destination"
  }

  $archive = Join-Path $ToolRoot "zig-$Version.zip"
  Invoke-WebRequest `
    -Uri "https://ziglang.org/download/$Version/zig-x86_64-windows-$Version.zip" `
    -OutFile $archive
  if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $Sha256) {
    throw "Zig $Version archive checksum mismatch"
  }
  $extracted = Join-Path $ToolRoot "zig-x86_64-windows-$Version"
  if (Test-Path -LiteralPath $extracted) {
    Remove-Item -LiteralPath $extracted -Recurse -Force
  }
  # The Windows inbox bsdtar extracts the checksum-verified archive an order of
  # magnitude faster than Expand-Archive; fall back when it is unavailable.
  $tar = Join-Path $env:SystemRoot "System32\tar.exe"
  $expanded = $false
  if (Test-Path -LiteralPath $tar -PathType Leaf) {
    & $tar -xf $archive -C $ToolRoot
    $expanded = $LASTEXITCODE -eq 0
    if (-not $expanded -and (Test-Path -LiteralPath $extracted)) {
      Remove-Item -LiteralPath $extracted -Recurse -Force
    }
  }
  if (-not $expanded) {
    Expand-Archive -LiteralPath $archive -DestinationPath $ToolRoot -Force
  }
  Move-Item `
    -LiteralPath (Join-Path $ToolRoot "zig-x86_64-windows-$Version") `
    -Destination $destination
  Remove-Item -LiteralPath $archive -Force
  return $executable
}

function Install-Provider([object] $Pin, [string] $Name) {
  $destination = Join-Path $ProviderRoot $Name
  $gitDirectory = Join-Path $destination ".git"
  $checkoutMarker = Join-Path $gitDirectory "graphcode-bootstrap-checkout"
  $existingCheckout = Test-Path -LiteralPath $gitDirectory -PathType Container
  $recoverCheckout = $existingCheckout -and
    (Test-Path -LiteralPath $checkoutMarker -PathType Leaf)
  if (-not $existingCheckout) {
    git -c core.longpaths=true clone --no-checkout $Pin.remoteUrl $destination
    if ($LASTEXITCODE -ne 0) {
      throw "Cloning $Name failed"
    }
  }

  git -C $destination config --local core.longpaths true
  if ($LASTEXITCODE -ne 0) {
    throw "Configuring long-path support for $Name failed"
  }
  if ($existingCheckout -and -not $recoverCheckout) {
    $status = @(git -c core.longpaths=true -C $destination status `
        --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
      throw "Inspecting $Name provider checkout failed"
    }
    if ($status.Count -ne 0) {
      throw "$Name provider checkout is dirty: $destination"
    }
  }

  git -c core.longpaths=true -C $destination fetch --quiet origin $Pin.sha
  if ($LASTEXITCODE -ne 0) {
    throw "Fetching $Name pin $($Pin.sha) failed"
  }
  if (-not $recoverCheckout) {
    Set-Content -LiteralPath $checkoutMarker -Value $Pin.sha -NoNewline
  }
  if ($recoverCheckout) {
    git -c core.longpaths=true -C $destination checkout --force --quiet `
      --detach $Pin.sha
  } else {
    git -c core.longpaths=true -C $destination checkout --quiet --detach $Pin.sha
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Checking out $Name pin $($Pin.sha) failed"
  }
  $status = @(git -c core.longpaths=true -C $destination status `
      --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "Inspecting $Name provider checkout failed"
  }
  if ($status.Count -ne 0) {
    throw "$Name provider checkout is dirty: $destination"
  }
  Remove-Item -LiteralPath $checkoutMarker -Force
  return $destination
}

function Resolve-Swift633 {
  $candidates = @(
    Get-ChildItem `
      (Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains") `
      -Recurse -Filter swift.exe -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName
  )
  foreach ($candidate in $candidates) {
    if ($candidate -match "\\Toolchains\\6\.3\.3[^\\]*\\usr\\bin\\swift\.exe$") {
      return $candidate
    }
    $version = & $candidate --version 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $version -match "Swift version 6\.3\.3") {
      return $candidate
    }
  }
  return $null
}

$zig0152 = Install-Zig `
  "0.15.2" `
  "3A0ED1E8799A2F8CE2A6E6290A9FF22E6906F8227865911FB7DDEDC3CC14CB0C"
$zig0160 = Install-Zig `
  "0.16.0" `
  "68659EB5F1E4EB1437A722F1DD889C5A322C9954607F5EDCF337BC3684A75A7E"

$pins = Get-Content `
  -LiteralPath (Join-Path $repoRoot "graphcode-windows\provider-pins.json") `
  -Raw | ConvertFrom-Json
$winghosttyRoot = Install-Provider $pins.winghostty "winghostty"
$zmxRoot = Install-Provider $pins.zmx "zmx"

$swift = Resolve-Swift633
if (-not $swift -and -not $SkipSwift) {
  winget install --id Swift.Toolchain --exact --version 6.3.3 `
    --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    throw "Installing Swift 6.3.3 failed"
  }
  $swift = Resolve-Swift633
}
if (-not $swift -and -not $SkipSwift) {
  throw "Swift 6.3.3 was installed but swift.exe could not be located"
}

$values = [ordered]@{
  GRAPHCODE_ZIG0152 = $zig0152
  GRAPHCODE_ZIG0160 = $zig0160
  GRAPHCODE_WINGHOSTTY_ROOT = $winghosttyRoot
  GRAPHCODE_ZMX_ROOT = $zmxRoot
}
if ($swift) {
  $values["GRAPHCODE_SWIFT633"] = $swift
}

foreach ($entry in $values.GetEnumerator()) {
  [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
  if ($env:GITHUB_ENV) {
    "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $env:GITHUB_ENV
  }
}

$environmentScript = Join-Path $ToolRoot "environment.ps1"
$values.GetEnumerator() |
  ForEach-Object { "`$env:$($_.Key) = '$($_.Value.Replace("'", "''"))'" } |
  Set-Content -LiteralPath $environmentScript

Write-Host "GraphCode Windows dependencies are ready."
Write-Host "Load them in a new shell with: . '$environmentScript'"
Write-Host "Validate with:"
Write-Host "pwsh -NoProfile -File Tools\windows\validate.ps1 -Task windows-shell -SwiftExecutable '$swift'"
