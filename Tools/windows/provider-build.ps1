[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $WinghosttyRoot,
  [Parameter(Mandatory)]
  [string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [string] $PinsPath,
  [ValidateRange(1, 5)]
  [int] $ZmxAttempts = 3
)

# Build-only compile of the pinned providers with the canonical flags that the
# provider cache key names (-emit-win32-host, x86_64-windows-gnu). It runs no
# terminal tests or smoke, so CI can seed the provider cache from a complete
# build before any gate. terminal-gate.ps1 and windows-shell.ps1 call it too.
$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not $PinsPath) {
  $PinsPath = Join-Path $repoRoot "graphcode-windows\provider-pins.json"
}
$pins = Get-Content -LiteralPath $PinsPath -Raw | ConvertFrom-Json

function Assert-PinnedCleanWorktree([string] $root, [string] $expectedSha, [string] $label) {
  if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "$label provider root is not a Git worktree: $root"
  }
  $status = @(git -C $root status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "$label provider status failed"
  }
  if ($status.Count -ne 0) {
    throw "$label provider worktree is dirty; use a clean pinned worktree or immutable artifact"
  }
  $actual = git -C $root rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $actual -ne $expectedSha) {
    throw "$label pin expected $expectedSha but found $actual"
  }
}

function Invoke-ProviderStep(
  [string] $label,
  [string] $root,
  [string] $zig,
  [string[]] $arguments,
  [string] $artifact,
  [int] $attempts
) {
  $artifactPath = Join-Path $root $artifact
  $exitCode = 0
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    Write-Host "==> $label provider artifact (attempt $attempt/$attempts): zig $($arguments -join ' ')"
    Push-Location $root
    try { & $zig @arguments; $exitCode = $LASTEXITCODE } finally { Pop-Location }
    if ($exitCode -eq 0) { break }
    if ($attempt -lt $attempts) { Start-Sleep -Seconds (5 * $attempt) }
  }
  if ($exitCode -ne 0) {
    throw "$label provider build failed after $attempts attempt(s) with exit code $exitCode"
  }
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "$label provider build did not produce $artifact"
  }
  Write-Output "PROVIDER_BUILD_STEP=$label artifact=$artifact"
}

Assert-PinnedCleanWorktree $WinghosttyRoot $pins.winghostty.sha "Winghostty"
Assert-PinnedCleanWorktree $ZmxRoot $pins.zmx.sha "zmx"

$executed = 0
Invoke-ProviderStep "Winghostty" $WinghosttyRoot $Zig0152 @("build", "-Demit-win32-host=true") `
  "zig-out\lib\winghostty-win32-host.lib" 1
$executed++
Invoke-ProviderStep "zmx" $ZmxRoot $Zig0160 @("build", "-Dtarget=x86_64-windows-gnu") `
  "zig-out\bin\zmx.exe" $ZmxAttempts
$executed++

# Build outputs are ignored by the providers; a dirty tree here means the build
# changed tracked sources and the result must not be cached.
Assert-PinnedCleanWorktree $WinghosttyRoot $pins.winghostty.sha "Winghostty"
Assert-PinnedCleanWorktree $ZmxRoot $pins.zmx.sha "zmx"
Write-Output "PROVIDER_BUILD_EXECUTED=$executed"
exit 0
