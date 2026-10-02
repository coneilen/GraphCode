[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$appPath = Join-Path $repoRoot "graphcode-windows\src\App.zig"
$mainPath = Join-Path $repoRoot "graphcode-windows\src\main.zig"
$buildPath = Join-Path $repoRoot "graphcode-windows\build.zig"
$packagePath = Join-Path $repoRoot "Tools\windows\package.ps1"
$app = Get-Content -LiteralPath $appPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw
$package = Get-Content -LiteralPath $packagePath -Raw
$checks = 0

function Require([bool] $condition, [string] $message) {
  if (-not $condition) { throw $message }
  $script:checks++
}

function Get-FunctionBody([string] $source, [string] $name) {
  $match = [regex]::Match(
    $source,
    "(?m)^\s*(?:pub\s+)?fn\s+$([regex]::Escape($name))\s*\("
  )
  if (-not $match.Success) { throw "production function '$name' was not found" }
  $next = [regex]::Match(
    $source.Substring($match.Index + $match.Length),
    "(?m)^\s*(?:pub\s+)?fn\s+[A-Za-z0-9_]+\s*\("
  )
  $end = if ($next.Success) {
    $match.Index + $match.Length + $next.Index
  } else {
    $source.Length
  }
  return $source.Substring($match.Index, $end - $match.Index)
}

$message = "Worktrees are deferred for this preview"
Require ($app.Contains($message)) `
  "RED: production Worktrees routes do not expose the required preview deferral message"

$guardedFunctions = @(
  "inspectWorktrees",
  "inspectWorktreesImpl",
  "presentWorktreeSweep",
  "reclaimWorktrees",
  "reclaimWorktreeOffer",
  "keepWorktreeOffer",
  "editWorktreePolicy",
  "saveCurrentWorktreePolicy",
  "toggleAllowReclaim",
  "toggleConfirmReclaim",
  "revealSelectedWorktree",
  "selectWorktreeRow",
  "toggleWorktreeRow",
  "moveWorktreeSelection",
  "applyUiaWorktreeSelection"
)
foreach ($name in $guardedFunctions) {
  $body = Get-FunctionBody $app $name
  Require ($body.Contains("guardWorktreesPreview")) `
    "RED: production Worktrees route '$name' bypasses the centralized preview guard"
}

$routeContracts = @(
  "if (action == .inspect_worktrees)",
  ".inspect_project_worktrees => if (selected) self.inspectWorktrees()",
  ".inspect_project_worktrees => if (graph.project.isLocalFilesystem()) self.inspectWorktrees()",
  ".inspect_worktrees => self.inspectWorktrees()",
  ".reclaim_worktrees => self.reclaimWorktrees()",
  ".edit_worktree_policy => self.editWorktreePolicy()",
  ".save_worktree_policy => self.saveCurrentWorktreePolicy()",
  ".header_worktree => return self.invokeHeader(.inspect_worktrees)",
  ".inspect_worktrees => self.inspectWorktrees(),",
  "6 => app.inspectWorktrees()",
  "7 => app.reclaimWorktrees()",
  "12 => app.toggleAllowReclaim()",
  "13 => app.toggleConfirmReclaim()",
  ".reclaim => self.reclaimWorktreeOffer(offer.path)"
)
foreach ($route in $routeContracts) {
  Require ($app.Contains($route)) `
    "production Worktrees route no longer funnels through the guarded action: '$route'"
}

$inspection = Get-FunctionBody $app "inspectWorktreesImpl"
$guardIndex = $inspection.IndexOf("guardWorktreesPreview")
$inspectIndex = $inspection.IndexOf("WorktreeStatus.inspect")
Require ($guardIndex -ge 0 -and $inspectIndex -gt $guardIndex) `
  "RED: WorktreeStatus.inspect is reachable before the preview guard"
Require ($app.Contains("worktree_inspection_attempt_count")) `
  "RED: guarded-route inspection call count is not observable"
Require ($build -match 'b\.option\(\s*bool,\s*"worktrees-deferred"') `
  "RED: the Windows build has no explicit Worktrees preview option"
Require ($build.Contains('addOption(bool, "worktrees_deferred"')) `
  "RED: the Worktrees preview option is not compiled into the product"
Require ($package.Contains('"-Dworktrees-deferred=$worktreesDeferred"')) `
  "RED: release packaging does not pass the Worktrees preview option"
Require ($package.Contains("--worktrees-preview-state")) `
  "RED: packaging does not verify the built product's Worktrees preview state"
Require ($main.Contains('"--worktrees-preview-state"')) `
  "RED: the packaged product cannot report its compiled Worktrees preview state"

foreach ($unchanged in @(
    'New Quick Chat\tCtrl+Q',
    "Open Global Overview",
    'Jump to Loop...\tCtrl+J',
    'Settings...\tCtrl+Shift+,'
  )) {
  $mainWindow = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\src\MainWindow.zig") -Raw
  Require ($mainWindow.Contains($unchanged)) `
    "non-Worktrees menu contract changed: '$unchanged'"
}

Write-Host "Worktree preview guard contracts: $checks passed"
