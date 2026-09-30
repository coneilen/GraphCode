$ErrorActionPreference = "Stop"

function Assert-ShellHostPrerequisite([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Validation driver does not parse" }
  $clauses = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true).Clauses | Where-Object { $_.Item1.Value -eq "windows-shell" })
  if ($clauses.Count -ne 1) { throw "Expected one windows-shell validation branch" }
  $body = $clauses[0].Item2
  $commands = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst]
    }, $true))
  $build = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned Winghostty host build for App contracts"'
    })
  $contracts = @($commands | Where-Object {
      $_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
        $_.CommandElements[0].Extent.Text -match 'Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1'
    })
  $smoke = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned GraphCode Windows shell build and smoke"'
    })
  $guards = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.IfStatementAst]
    }, $true))
  $pin = @($guards | Where-Object { $_.Extent.Text -match '\$actualWinghosttyPin -ne \$pins\.winghostty\.sha' })
  $clean = @($guards | Where-Object { $_.Extent.Text -match '\$providerStatus\.Count -ne 0' })
  $library = @($guards | Where-Object { $_.Extent.Text -match 'Test-Path -LiteralPath \$winghosttyLib -PathType Leaf' })
  foreach ($stage in @(@{ Values = $build }, @{ Values = $contracts }, @{ Values = $smoke },
      @{ Values = $pin }, @{ Values = $clean }, @{ Values = $library })) {
    if ($stage.Values.Count -ne 1) { throw "Missing or repeated App host prerequisite stage" }
  }
  if ($clean[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $pin[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $build[0].Extent.EndOffset -ge $library[0].Extent.StartOffset -or
      $library[0].Extent.EndOffset -ge $contracts[0].Extent.StartOffset -or
      $contracts[0].Extent.EndOffset -ge $smoke[0].Extent.StartOffset -or
      $build[0].Extent.Text -notmatch '(?s)Push-Location \$winghosttyRoot.*& \$zig0152 build -Demit-win32-host=true.*finally \{ Pop-Location \}') {
    throw "Pinned host validation/build must precede App contracts, which must precede live smoke"
  }
}

function Get-WorkflowJobs([string] $text) {
  # Windows checkouts may convert workflow files to CRLF.
  $text = $text.Replace("`r`n", "`n")
  $jobsAt = [regex]::Match($text, '(?m)^jobs:\s*$')
  if (-not $jobsAt.Success) { throw "Workflow has no jobs block" }
  $body = $text.Substring($jobsAt.Index + $jobsAt.Length)
  $heads = @([regex]::Matches($body, '(?m)^  ([A-Za-z0-9_-]+):[ \t]*$'))
  $jobs = [ordered]@{}
  for ($index = 0; $index -lt $heads.Count; $index++) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $body.Length }
    $jobs[$heads[$index].Groups[1].Value] = $body.Substring($heads[$index].Index, $end - $heads[$index].Index)
  }
  $jobs
}

# Every validate.ps1 invocation a pull request runs, expanded over its matrix,
# must together cover exactly what `validate.ps1 -Task all` covers: every task,
# every Windows shell unit shard plus the integration part, and both packaging
# parts. Jobs gated to schedule/dispatch (a positive event_name test) are not
# pull request coverage.
function Test-CiPartitionCoverage([string] $runner, [string] $pwsh, [string] $repoRoot) {
  $expectedTasks = @(& $runner -List)
  $lines = [Collections.Generic.List[string]]::new()
  foreach ($file in @("windows-shell.yml", "windows-port-validation.yml", "windows-hardening.yml")) {
    $jobs = Get-WorkflowJobs (Get-Content (Join-Path $repoRoot ".github\workflows\$file") -Raw)
    foreach ($job in $jobs.GetEnumerator()) {
      if ($job.Value -match '(?m)^    if:.*github\.event_name ==') { continue }
      $shards = @("")
      $matrix = [regex]::Match($job.Value, '(?m)^\s+shard:\s*\[([0-9, ]+)\]')
      if ($matrix.Success) { $shards = @($matrix.Groups[1].Value -split ',\s*') }
      foreach ($run in [regex]::Matches($job.Value, '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 (.+)$')) {
        foreach ($shard in $shards) {
          $arguments = $run.Groups[1].Value.Replace('${{ matrix.shard }}', $shard)
          if ($arguments -match '\$\{\{') { throw "Unsupported workflow expression in validate.ps1 arguments: $arguments" }
          $output = @(& $pwsh -NoProfile -Command "& '$runner' $arguments -DryRun")
          if ($LASTEXITCODE -ne 0) { throw "Workflow validate.ps1 arguments failed a dry run: $arguments" }
          foreach ($line in $output) { if ("$line" -match '^task=') { $lines.Add("$line") } }
        }
      }
    }
  }
  $coveredTasks = @($lines | ForEach-Object { ($_ -split ' ')[0].Substring(5) } | Sort-Object -Unique)
  $missingTasks = @($expectedTasks | Where-Object { $coveredTasks -notcontains $_ })
  if ($missingTasks.Count -ne 0) {
    throw "RED: pull request CI no longer runs validation tasks: $($missingTasks -join ', ')"
  }
  Assert-PartCoverage $lines
}

function Assert-PartCoverage([string[]] $lines) {
  $shell = @($lines | Where-Object { $_ -like "task=windows-shell *" } | ForEach-Object {
      $match = [regex]::Match($_, 'part=(\w+) shard=(\d+)/(\d+)')
      [pscustomobject]@{ Part = $match.Groups[1].Value; Shard = [int]$match.Groups[2].Value; Count = [int]$match.Groups[3].Value }
    })
  if (-not @($shell | Where-Object { $_.Part -ne "unit" }).Count) {
    throw "RED: pull request CI does not run the Windows shell integration part"
  }
  $unitComplete = $false
  foreach ($group in @($shell | Where-Object { $_.Part -ne "integration" } | Group-Object Count)) {
    $count = [int]$group.Name
    $seen = @($group.Group | ForEach-Object { $_.Shard } | Sort-Object -Unique)
    if ($seen.Count -eq $count -and ($seen -join ',') -eq ((0..($count - 1)) -join ',')) { $unitComplete = $true }
  }
  if (-not $unitComplete) { throw "RED: pull request CI does not run every Windows shell unit shard" }
  $packaging = @($lines | Where-Object { $_ -like "task=packaging *" } | ForEach-Object { ($_ -split 'part=')[1] })
  if ($packaging -notcontains "all" -and ($packaging -notcontains "contracts" -or $packaging -notcontains "real")) {
    throw "RED: pull request CI does not run both packaging parts"
  }
}

function Test-CiAggregateGates([string] $repoRoot, [string] $pwsh) {
  foreach ($gate in @(
      @{ File = "windows-shell.yml"; Job = "windows-shell"; Exempt = @() },
      @{ File = "windows-port-validation.yml"; Job = "windows-spikes"; Exempt = @("investigation-privacy") })) {
    $jobs = Get-WorkflowJobs (Get-Content (Join-Path $repoRoot ".github\workflows\$($gate.File)") -Raw)
    if (-not $jobs.Contains($gate.Job)) { throw "RED: required check job '$($gate.Job)' is missing" }
    $aggregate = $jobs[$gate.Job]
    if ($aggregate -match '(?m)^    name:') { throw "RED: '$($gate.Job)' must keep its job id as the required check name" }
    $needs = [regex]::Match($aggregate, '(?m)^    needs:\s*\[([^\]]+)\]')
    if (-not $needs.Success) { throw "RED: '$($gate.Job)' does not need its parts" }
    $needed = @($needs.Groups[1].Value -split ',\s*' | ForEach-Object { $_.Trim() })
    foreach ($name in $jobs.Keys) {
      if ($name -ne $gate.Job -and $gate.Exempt -notcontains $name -and $needed -notcontains $name) {
        throw "RED: '$($gate.Job)' does not wait for part '$name'"
      }
    }
    if ($aggregate -notmatch '(?m)^    if: \$\{\{ !cancelled\(\) \}\}\s*$' -or
        $aggregate -notmatch 'NEEDS_JSON: \$\{\{ toJSON\(needs\) \}\}' -or
        $aggregate -notmatch 'Assert-CiPartResults\.ps1 -NeedsJson \$env:NEEDS_JSON -Required \$env:WINDOWS_REQUIRED') {
      throw "RED: '$($gate.Job)' does not fail unless every part succeeded"
    }
  }
  $gateScript = Join-Path $repoRoot "Tools\windows\Assert-CiPartResults.ps1"
  foreach ($case in @(
      @{ Required = "true"; Results = @{ changes = "success"; a = "success"; b = "success" }; Pass = $true },
      @{ Required = "true"; Results = @{ changes = "success"; a = "success"; b = "skipped" }; Pass = $false },
      @{ Required = "true"; Results = @{ changes = "failure"; a = "success"; b = "failure" }; Pass = $false },
      @{ Required = "true"; Results = @{ changes = "success"; a = "cancelled"; b = "success" }; Pass = $false },
      @{ Required = "false"; Results = @{ changes = "success"; a = "skipped"; b = "skipped" }; Pass = $true },
      @{ Required = "false"; Results = @{ changes = "success"; a = "failure"; b = "skipped" }; Pass = $false },
      @{ Required = "false"; Results = @{ changes = "failure"; a = "skipped"; b = "skipped" }; Pass = $false })) {
    $needsJson = [ordered]@{}
    foreach ($entry in $case.Results.GetEnumerator()) { $needsJson[$entry.Key] = @{ result = $entry.Value; outputs = @{} } }
    & $pwsh -NoProfile -File $gateScript -NeedsJson ($needsJson | ConvertTo-Json -Compress -Depth 4) -Required $case.Required *> $null
    if (($LASTEXITCODE -eq 0) -ne $case.Pass) {
      throw "RED: aggregate gate decided wrongly for required=$($case.Required) $($case.Results | ConvertTo-Json -Compress)"
    }
  }
}

function Get-WorkflowSteps([string] $jobText) {
  $jobText = $jobText.Replace("`r`n", "`n")
  $heads = @([regex]::Matches($jobText, '(?m)^      - '))
  $steps = [Collections.Generic.List[string]]::new()
  for ($index = 0; $index -lt $heads.Count; $index++) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $jobText.Length }
    $steps.Add($jobText.Substring($heads[$index].Index, $end - $heads[$index].Index))
  }
  , $steps.ToArray()
}

# A cold provider cache miss must be able to seed its own immutable key even
# when a later gate fails or is cancelled, but never from a partial tree: the
# single save runs after a successful bootstrap, pin check, and build-only
# provider compile, and before any gate. Implicit success() gating (an `if:`
# without a status-check function) or an explicit success()/always() would
# reinstate whole-job gating or publish a failed build.
$script:ProviderCacheSaveCondition = "`${{ !cancelled() && steps.bootstrap.conclusion == 'success' && steps.verify-pins.conclusion == 'success' && steps.provider-build.conclusion == 'success' && steps.provider-cache.outputs.cache-hit != 'true' }}"
function Assert-ProviderCacheSeeding([string] $jobText, [string] $label, [bool] $requireGate) {
  $steps = Get-WorkflowSteps $jobText
  function Find-Step([scriptblock] $predicate) {
    for ($index = 0; $index -lt $steps.Count; $index++) {
      if (& $predicate $steps[$index]) { return $index }
    }
    return -1
  }
  $restore = Find-Step { param($s) $s -match '(?m)^        id: provider-cache\s*$' -and $s -match 'actions/cache/restore@' }
  $bootstrap = Find-Step { param($s) $s -match '(?m)^        id: bootstrap\s*$' -and $s -match '(?m)^        run: \./Tools/windows/bootstrap\.ps1 ' }
  $verify = Find-Step { param($s) $s -match '(?m)^        id: verify-pins\s*$' -and $s -match '(?m)^        run: \./Tools/windows/Assert-ProviderCheckout\.ps1 -ProviderRoot \.ci-providers\s*$' }
  $build = Find-Step { param($s) $s -match '(?m)^        id: provider-build\s*$' -and $s -match '(?m)^        run: \./Tools/windows/validate\.ps1 -Task provider-build\s*$' }
  $saves = @(for ($index = 0; $index -lt $steps.Count; $index++) { if ($steps[$index] -match 'actions/cache/save@') { $index } })
  $gate = Find-Step { param($s) $s -match '(?m)^        run: \./Tools/windows/validate\.ps1 -Task windows-shell\b' }
  foreach ($required in @(
      @{ Index = $restore; Name = "provider cache restore (id provider-cache)" },
      @{ Index = $bootstrap; Name = "bootstrap (id bootstrap)" },
      @{ Index = $verify; Name = "pin verification (id verify-pins)" },
      @{ Index = $build; Name = "build-only provider compile (id provider-build, validate.ps1 -Task provider-build)" })) {
    if ($required.Index -lt 0) { throw "RED: $label has no $($required.Name) before its provider cache save" }
  }
  if ($saves.Count -ne 1) { throw "RED: $label must have exactly one provider cache save, found $($saves.Count)" }
  $save = $saves[0]
  if ($requireGate -and $gate -lt 0) { throw "RED: $label has no downstream windows-shell gate" }
  if (-not ($restore -lt $bootstrap -and $bootstrap -lt $verify -and $verify -lt $build -and $build -lt $save)) {
    throw "RED: $label does not save only after restore, bootstrap, pin verification, and build-only compile"
  }
  if ($requireGate -and $save -gt $gate) {
    throw "RED: $label saves the provider cache after the gate, so a failed or cancelled gate discards a cold build"
  }
  $saveText = $steps[$save]
  $condition = [regex]::Match($saveText, '(?m)^        if:\s*(.+?)\s*$')
  if (-not $condition.Success) { throw "RED: $label provider cache save has no explicit condition" }
  $conditionText = $condition.Groups[1].Value
  if ($conditionText -match '(?<![\w.])(success|always)\(\)') {
    throw "RED: $label provider cache save uses whole-job success()/always() gating"
  }
  if ($conditionText -notmatch '!cancelled\(\)') {
    throw "RED: $label provider cache save omits a status-check function, which implicitly reinstates whole-job success() gating"
  }
  if ($conditionText -cne $script:ProviderCacheSaveCondition) {
    throw "RED: $label provider cache save is not gated on bootstrap, pin, and build-only success on a cache miss: $conditionText"
  }
  if ($saveText -notmatch '(?m)^            \.ci-providers\s*$' -or
      $saveText -notmatch '(?m)^            \.ci-tools/zig-global\s*$' -or
      $saveText -notmatch '(?m)^          key: \$\{\{ steps\.provider-cache\.outputs\.cache-primary-key \}\}\s*$') {
    throw "RED: $label provider cache save does not publish the complete immutable provider tree under its restored key"
  }
  if ($jobText -match 'continue-on-error') {
    throw "RED: $label lets a failed provider step continue into the cache save"
  }
}

function Test-ProviderCacheSeeding([string] $shellWorkflow, [string] $warmerWorkflow) {
  $shellJobs = Get-WorkflowJobs $shellWorkflow
  $warmerJobs = Get-WorkflowJobs $warmerWorkflow
  Assert-ProviderCacheSeeding $shellJobs["shell-integration"] "windows-shell integration" $true
  Assert-ProviderCacheSeeding $warmerJobs["warm"] "Windows cache warmer" $false
  if ([regex]::Matches($shellWorkflow, 'actions/cache/save@').Count -ne 1) {
    throw "RED: windows-shell integration must stay the sole provider cache writer"
  }
  foreach ($job in $shellJobs.GetEnumerator()) {
    if ($job.Key -eq "shell-integration") { continue }
    foreach ($step in (Get-WorkflowSteps $job.Value)) {
      if ($step -match '(?m)^\s+\.ci-providers\s*$' -and $step -notmatch 'actions/cache/restore@') {
        throw "RED: $($job.Key) must restore the provider cache read-only"
      }
    }
  }
  $bootstrapCap = [regex]::Match($warmerJobs["warm"], '(?s)id: bootstrap.*?timeout-minutes: (\d+)')
  $buildCap = [regex]::Match($warmerJobs["warm"], '(?s)id: provider-build.*?timeout-minutes: (\d+)')
  $outerCap = [regex]::Match($warmerJobs["warm"], '(?m)^    timeout-minutes: (\d+)\s*$')
  if (-not $bootstrapCap.Success -or -not $buildCap.Success -or -not $outerCap.Success) {
    throw "RED: Windows cache warmer bootstrap, build-only, and job caps must all be explicit"
  }
  # Healthy cold bootstrap measured 26m34s (job 109675286607); the warmer's own
  # 30m cap was exceeded on run 36645791783 attempt 1.
  if ([int]$bootstrapCap.Groups[1].Value -lt 35) {
    throw "RED: Windows cache warmer bootstrap cap leaves no headroom over a healthy 26m34s cold bootstrap"
  }
  if ([int]$outerCap.Groups[1].Value -le [int]$bootstrapCap.Groups[1].Value + [int]$buildCap.Groups[1].Value) {
    throw "RED: Windows cache warmer job cap truncates a bootstrap and build-only phase that both stay within their step caps"
  }
  # Cold integration, measured per phase: setup and Swift 1m54s (job 109703426776),
  # bootstrap 26m34s (job 109675286607), build-only 4m01s and save 10s
  # (job 109703426776), gate without the provider build up to 7m17s
  # (job 109694707284), post 10s: 40m06s. The former 35m cap cancelled 109675286607.
  $integrationCap = [regex]::Match($shellJobs["shell-integration"], '(?m)^    timeout-minutes: (\d+)\s*$')
  if (-not $integrationCap.Success -or [int]$integrationCap.Groups[1].Value -lt 41) {
    throw "RED: windows-shell integration job cap truncates a measured cold bootstrap, build-only, save, and gate (40m08s)"
  }
}

function Test-ProviderCacheSeedingMutations([string] $shellWorkflow, [string] $warmerWorkflow) {
  $shell = $shellWorkflow.Replace("`r`n", "`n")
  $warmer = $warmerWorkflow.Replace("`r`n", "`n")
  $condition = $script:ProviderCacheSaveCondition
  $integration = (Get-WorkflowJobs $shell)["shell-integration"]
  $steps = Get-WorkflowSteps $integration
  $saveStep = @($steps | Where-Object { $_ -match 'actions/cache/save@' })[0]
  $gateStep = @($steps | Where-Object { $_ -match 'validate\.ps1 -Task windows-shell\b' })[0]
  $buildStep = @($steps | Where-Object { $_ -match 'id: provider-build' })[0]
  if (-not $saveStep -or -not $gateStep -or -not $buildStep) { throw "Cannot construct provider cache seeding mutations" }
  $afterGate = $integration.Replace($saveStep, "").Replace($gateStep, $gateStep + $saveStep)
  $mutations = [ordered]@{
    "explicit whole-job success()" = $shell.Replace($condition, "`${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}")
    "implicit success() (no status-check function)" = $shell.Replace($condition, $condition.Replace("!cancelled() && ", ""))
    "always() saves a failed build" = $shell.Replace($condition, $condition.Replace("!cancelled()", "always()"))
    "build outcome not required" = $shell.Replace($condition, $condition.Replace(" && steps.provider-build.conclusion == 'success'", ""))
    "cache hit re-saved" = $shell.Replace($condition, $condition.Replace(" && steps.provider-cache.outputs.cache-hit != 'true'", ""))
    "save after gate" = $shell.Replace($integration, $afterGate)
    "clone-only tree (no build-only step)" = $shell.Replace($buildStep, "")
    "build step replaced by bootstrap" = $shell.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build", "run: ./Tools/windows/bootstrap.ps1 -ToolRoot .ci-tools -ProviderRoot .ci-providers")
    "partial tree without zig-global" = $shell.Replace($saveStep, $saveStep.Replace("            .ci-tools/zig-global`n", ""))
    "failed build continues" = $shell.Replace($buildStep, $buildStep.Replace("        shell: pwsh", "        continue-on-error: true`n        shell: pwsh"))
    "second provider cache writer" = $shell.Replace("uses: actions/cache/restore@", "uses: actions/cache@")
  }
  foreach ($mutation in $mutations.GetEnumerator()) {
    if ($mutation.Value -ceq $shell) { throw "Provider cache seeding mutation did not apply: $($mutation.Key)" }
    $rejected = $false
    try { Test-ProviderCacheSeeding $mutation.Value $warmer } catch { $rejected = $true }
    if (-not $rejected) { throw "RED: provider cache seeding contract accepted mutation: $($mutation.Key)" }
  }
  $warmerMutations = [ordered]@{
    "warmer runs terminal tests" = $warmer.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build", "run: ./Tools/windows/validate.ps1 -Task terminal-gate")
    "warmer whole-job success()" = $warmer.Replace($condition, "`${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}")
    "warmer 30m bootstrap cap" = [regex]::Replace($warmer, '(?s)(id: bootstrap.*?timeout-minutes: )\d+', '${1}30')
  }
  foreach ($mutation in $warmerMutations.GetEnumerator()) {
    if ($mutation.Value -ceq $warmer) { throw "Warmer mutation did not apply: $($mutation.Key)" }
    $rejected = $false
    try { Test-ProviderCacheSeeding $shell $mutation.Value } catch { $rejected = $true }
    if (-not $rejected) { throw "RED: provider cache seeding contract accepted warmer mutation: $($mutation.Key)" }
  }
}

# provider-build.ps1 must compile both pinned providers, report a positive
# executed build count, run no terminal tests, and reject a partial build.
function Test-ProviderBuildScript([string] $repoRoot, [string] $pwsh) {
  $script = Join-Path $repoRoot "Tools\windows\provider-build.ps1"
  if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "RED: build-only provider script is missing: $script"
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) "gc-provider-build-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force $scratch | Out-Null
  try {
    $fakeZig = Join-Path $scratch "fake-zig.cmd"
    Set-Content -LiteralPath $fakeZig -Encoding ascii -Value @(
      '@echo off',
      'echo FAKE_ZIG %*>> "%FAKE_ZIG_LOG%"',
      'if "%FAKE_ZIG_FAIL%"=="1" exit /b 7',
      'if "%FAKE_ZIG_SKIP_ARTIFACT%"=="1" exit /b 0',
      'echo %* | findstr /c:"-Demit-win32-host=true" >nul && (mkdir zig-out\lib 2>nul & type nul > zig-out\lib\winghostty-win32-host.lib)',
      'echo %* | findstr /c:"-Dtarget=x86_64-windows-gnu" >nul && (mkdir zig-out\bin 2>nul & type nul > zig-out\bin\zmx.exe)',
      'exit /b 0')
    $pins = [ordered]@{ schemaVersion = 1 }
    foreach ($name in @("winghostty", "zmx")) {
      $root = Join-Path $scratch $name
      New-Item -ItemType Directory -Force $root | Out-Null
      git -C $root init -q 2>$null
      "zig-out/`n" | Set-Content -LiteralPath (Join-Path $root ".gitignore") -NoNewline
      git -C $root add .gitignore
      git -C $root -c user.name=t -c user.email=t@example.invalid commit -q -m pin 2>$null
      $pins[$name] = [ordered]@{ sha = (git -C $root rev-parse HEAD) }
    }
    $pinsPath = Join-Path $scratch "provider-pins.json"
    $pins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
    function Invoke-ProviderBuildCase([hashtable] $environment) {
      foreach ($name in @("winghostty", "zmx")) {
        Remove-Item -LiteralPath (Join-Path $scratch "$name\zig-out") -Recurse -Force -ErrorAction SilentlyContinue
      }
      $log = Join-Path $scratch "zig-$([guid]::NewGuid().ToString('N')).log"
      $saved = @{}
      $all = @{ FAKE_ZIG_LOG = $log; FAKE_ZIG_FAIL = $null; FAKE_ZIG_SKIP_ARTIFACT = $null }
      foreach ($entry in $environment.GetEnumerator()) { $all[$entry.Key] = $entry.Value }
      foreach ($entry in $all.GetEnumerator()) {
        $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
      }
      try {
        $output = @(& $pwsh -NoProfile -File $script `
            -WinghosttyRoot (Join-Path $scratch "winghostty") -ZmxRoot (Join-Path $scratch "zmx") `
            -Zig0152 $fakeZig -Zig0160 $fakeZig -PinsPath $pinsPath -ZmxAttempts 1 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
      } finally {
        foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value) }
      }
      $invocations = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
      [pscustomobject]@{ ExitCode = $exit; Output = $output; Invocations = $invocations }
    }
    $pass = Invoke-ProviderBuildCase @{}
    $text = $pass.Output -join "`n"
    $executed = [regex]::Match($text, '(?m)^PROVIDER_BUILD_EXECUTED=(\d+)\s*$')
    $stepLines = @($pass.Output | Where-Object { $_ -match '^PROVIDER_BUILD_STEP=' })
    if ($pass.ExitCode -ne 0 -or -not $executed.Success -or [int]$executed.Groups[1].Value -ne 2 -or
        $stepLines.Count -ne 2 -or $pass.Invocations.Count -ne 2) {
      throw "RED: provider-build.ps1 did not execute exactly two pinned provider builds (exit=$($pass.ExitCode)): $text"
    }
    if ($pass.Invocations[0] -notmatch '^FAKE_ZIG build -Demit-win32-host=true\s*$' -or
        $pass.Invocations[1] -notmatch '^FAKE_ZIG build -Dtarget=x86_64-windows-gnu\s*$') {
      throw "RED: provider-build.ps1 changed the canonical provider build flags: $($pass.Invocations -join '; ')"
    }
    if ($text -match '(?i)terminal gate|smoke|TerminalGate\.Tests|zmx send|uia') {
      throw "RED: provider-build.ps1 ran terminal tests or smoke: $text"
    }
    foreach ($case in @(
        @{ Name = "missing artifact"; Environment = @{ FAKE_ZIG_SKIP_ARTIFACT = "1" } },
        @{ Name = "failed compiler"; Environment = @{ FAKE_ZIG_FAIL = "1" } })) {
      $result = Invoke-ProviderBuildCase $case.Environment
      if ($result.ExitCode -eq 0 -or ($result.Output -join "`n") -match '(?m)^PROVIDER_BUILD_EXECUTED=') {
        throw "RED: provider-build.ps1 accepted a partial build ($($case.Name))"
      }
    }
    "untracked" | Set-Content -LiteralPath (Join-Path $scratch "zmx\dirty.txt")
    $dirty = Invoke-ProviderBuildCase @{}
    Remove-Item -LiteralPath (Join-Path $scratch "zmx\dirty.txt") -Force
    if ($dirty.ExitCode -eq 0 -or $dirty.Invocations.Count -ne 0) {
      throw "RED: provider-build.ps1 built from a dirty provider worktree"
    }
    $wrongPins = [ordered]@{ schemaVersion = 1; winghostty = $pins.winghostty; zmx = [ordered]@{ sha = ("0" * 40) } }
    $wrongPins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
    $wrong = Invoke-ProviderBuildCase @{}
    if ($wrong.ExitCode -eq 0 -or $wrong.Invocations.Count -ne 0) {
      throw "RED: provider-build.ps1 built an unpinned provider"
    }
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The Windows shell Zig sections are sharded across runners. A section passes
# only with a positive test count per `zig test` (a filter that matches nothing
# still exits 0), the shard plan is a complete disjoint partition, and the
# aggregate manifest check rejects missing, duplicated, or empty sections.
function Test-ShellSectionGate([string] $repoRoot, [string] $pwsh) {
  $shellTests = Join-Path $repoRoot "Tools\windows\Tests\WindowsShell.Tests.ps1"
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($shellTests, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-Native"
      }, $true)
    if (-not $definition) { throw "RED: WindowsShell.Tests.ps1 has no Invoke-Native section runner" }
    . ([scriptblock]::Create($definition.Extent.Text))
    $sectionCatalog = @("Probe section")
    $sectionPlan = [pscustomobject]@{ Assignment = @{ "Probe section" = 0 } }
    $Shard = 0
    $ShardCount = 1
    $executedSections = [Collections.Generic.List[object]]::new()
    foreach ($summary in @("All 0 tests passed.", "0 passed; 0 skipped; 1 failed.", "0 passed; 2 skipped; 0 failed.")) {
      $accepted = $true
      try {
        Invoke-Native "Probe section" ([scriptblock]::Create(
            "# `$zig test src\Probe.zig --test-filter nothing`nWrite-Output '$summary'; `$global:LASTEXITCODE = 0")) 6> $null
      } catch { $accepted = $false }
      if ($accepted) { throw "RED: a Windows shell section passed with no executed tests ($summary)" }
    }
    Invoke-Native "Probe section" {
      # $zig test src\Probe.zig
      # $zig test src\Other.zig
      Write-Output "All 3 tests passed."
      Write-Output "2 passed; 1 skipped; 0 failed."
      $global:LASTEXITCODE = 0
    } 6> $null
    if ($executedSections.Count -ne 1 -or $executedSections[0].positiveSummaries -ne 2 -or
        $executedSections[0].zigTestInvocations -ne 2) {
      throw "A Windows shell section with positive test counts was not recorded"
    }
  }

  $plans = @(0..2 | ForEach-Object {
      & $pwsh -NoProfile -File $shellTests -PlanOnly -Shard $_ -ShardCount 3 | Out-String | ConvertFrom-Json
    })
  $whole = & $pwsh -NoProfile -File $shellTests -PlanOnly | Out-String | ConvertFrom-Json
  $catalog = @($whole.catalog)
  if ($catalog.Count -lt 40 -or (@($whole.assigned) -join "`n") -cne ($catalog -join "`n")) {
    throw "RED: an unsharded Windows shell run does not execute the whole section catalog"
  }
  $assigned = @($plans | ForEach-Object { @($_.assigned) })
  if ($assigned.Count -ne $catalog.Count -or @($assigned | Sort-Object -Unique).Count -ne $catalog.Count -or
      @($catalog | Where-Object { $assigned -cnotcontains $_ }).Count -ne 0 -or
      @($plans | Where-Object { @($_.assigned).Count -eq 0 }).Count -ne 0) {
    throw "RED: the Windows shell shard plan is not a complete disjoint partition"
  }
  $shellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  if ($shellWorkflow -notmatch '(?m)^\s+shard: \[0, 1, 2\]\s*$' -or
      $shellWorkflow -notmatch '-ShellTestShardCount 3 ' -or
      $shellWorkflow -notmatch 'Test-ShellSectionManifests\.ps1 -Directory \.ci-sections -ShardCount 3') {
    throw "RED: the Windows shell shard matrix, plan, and coverage check disagree on the shard count"
  }

  $verifier = Join-Path $repoRoot "Tools\windows\Test-ShellSectionManifests.ps1"
  $scratch = Join-Path ([IO.Path]::GetTempPath()) "graphcode-shell-sections-$([guid]::NewGuid())"
  try {
    $mutations = @(
      @{ Name = "complete"; Pass = $true; Edit = { param($manifests) } },
      @{ Name = "missing section"; Pass = $false; Edit = { param($manifests)
          $manifests[1].executed = @($manifests[1].executed | Select-Object -Skip 1)
          $manifests[1].assigned = @($manifests[1].assigned | Select-Object -Skip 1) } },
      @{ Name = "duplicate section"; Pass = $false; Edit = { param($manifests)
          $manifests[0].executed = @($manifests[0].executed) + @($manifests[1].executed[0])
          $manifests[0].assigned = @($manifests[0].assigned) + @($manifests[1].assigned[0]) } },
      @{ Name = "zero tests"; Pass = $false; Edit = { param($manifests)
          $manifests[2].executed[0].positiveSummaries = 0 } },
      @{ Name = "skipped assignment"; Pass = $false; Edit = { param($manifests)
          $manifests[2].executed = @($manifests[2].executed | Select-Object -SkipLast 1) } },
      @{ Name = "missing shard"; Pass = $false; Edit = { param($manifests) $manifests[2] = $null } }
    )
    foreach ($mutation in $mutations) {
      $directory = Join-Path $scratch ($mutation.Name -replace ' ', '-')
      New-Item -ItemType Directory -Force $directory | Out-Null
      $manifests = @($plans | ForEach-Object {
          [pscustomobject]@{
            schemaVersion = 1
            shard = $_.shard
            shardCount = 3
            catalog = @($_.catalog)
            assigned = @($_.assigned)
            executed = @($_.assigned | ForEach-Object {
                [pscustomobject]@{ name = $_; seconds = 1; zigTestInvocations = 1; positiveSummaries = 1 }
              })
          }
        })
      & $mutation.Edit $manifests
      foreach ($manifest in @($manifests | Where-Object { $null -ne $_ })) {
        $manifest | ConvertTo-Json -Depth 6 |
          Set-Content -LiteralPath (Join-Path $directory "shard-$($manifest.shard).json")
      }
      & $pwsh -NoProfile -File $verifier -Directory $directory -ShardCount 3 *> $null
      if (($LASTEXITCODE -eq 0) -ne $mutation.Pass) {
        throw "RED: Windows shell section coverage decided wrongly for the $($mutation.Name) case"
      }
    }
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}
function Test-ZigResolverDiagnostics([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Resolver source does not parse" }
  foreach ($name in @("Invoke-ZigResolverProbe", "Write-ZigResolverDiagnostic", "Resolve-ZigVersion")) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
      }, $true)
    if ($null -eq $definition) { throw "Missing actual resolver helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  function Assert-Resolver([bool] $condition, [string] $message) {
    if (-not $condition) { throw "Zig diagnostic contract: $message" }
  }
  $environmentName = "GRAPHCODE_ZIG_RESOLVER_TEST"
  $priorEnvironment = [Environment]::GetEnvironmentVariable($environmentName)
  $priorExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
  $priorExitValue = if ($null -ne $priorExit) { $priorExit.Value } else { $null }
  try {
    function InMemoryZigProbe([string] $operation) {
      if ($operation -eq "throw") { throw [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY") }
      $global:LASTEXITCODE = -1073741502
      Write-Output "0.15.2"
      Write-Error "ghp_PRIVATE_CANARY" -ErrorAction Continue
    }
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "version"
    Assert-Resolver ($probe.Output -ceq "0.15.2" -and $probe.ExitCode -eq -1073741502) "actual probe lost stdout or native exit"
    Assert-Resolver ($probe.ErrorText -match "ghp_PRIVATE_CANARY" -and $null -eq $probe.Failure) "actual probe did not separate stderr"
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "throw"
    Assert-Resolver ($null -eq $probe.ExitCode -and $null -ne $probe.Failure) "launch failure reused stale LASTEXITCODE"

    $a = "C:\fixture\configured\zig.exe"
    $b = "C:\fixture\path\zig.exe"
    $c = "C:\fixture\discovered\zig.exe"
    $repoRoot = "C:\fixture\repo"
    $state = @{
      PathCandidate = $b; Discovered = @($c); Exists = @{}; Probes = @{}
      Calls = [Collections.Generic.List[string]]::new()
      Diagnostics = [Collections.Generic.List[string]]::new()
      Warnings = [Collections.Generic.List[string]]::new()
      WriterFails = $false
      WarningFails = $false
    }
    function Get-Command($Name, $ErrorAction) { [pscustomobject]@{ Source = $state.PathCandidate } }
    function Get-ChildItem($Path, [switch] $Recurse, $Filter, [switch] $File, $ErrorAction) {
      foreach ($entry in $state.Discovered) { [pscustomobject]@{ FullName = $entry } }
    }
    function Test-Path($LiteralPath, $PathType, $ErrorAction) { $state.Exists[$LiteralPath] -eq $true }
    function Resolve-Path($LiteralPath) { [pscustomobject]@{ Path = $LiteralPath } }
    function Invoke-ZigResolverProbe([string] $candidate, [string] $operation) {
      $key = "$candidate|$operation"
      $state.Calls.Add($key)
      if (-not $state.Probes.ContainsKey($key)) { throw "Unplanned in-memory probe" }
      $state.Probes[$key]
    }
    function Write-Host($Object) {
      if ($state.WriterFails) { throw "ghp_PRIVATE_CANARY" }
      $state.Diagnostics.Add([string]$Object)
    }
    function Write-Warning($Message, $WarningAction) {
      $state.Warnings.Add([string]$Message)
      if ($state.WarningFails) { throw "ghp_PRIVATE_CANARY" }
    }
    function New-Probe($output, $exitCode = 0, $stderr = "") {
      [pscustomobject]@{ Output = $output; ExitCode = $exitCode; ErrorText = $stderr; Failure = $null }
    }
    function Reset-ResolverCase {
      $state.Calls.Clear(); $state.Diagnostics.Clear(); $state.Warnings.Clear()
      $state.WriterFails = $false
      $state.WarningFails = $false
      $state.PathCandidate = $b
      $state.Discovered = @($a, $c)
      $state.Exists = @{ $a = $true; $b = $true; $c = $true }
      $state.Probes = @{}
      foreach ($candidate in @($a, $b, $c)) {
        $state.Probes["$candidate|version"] = New-Probe "0.15.2"
        $state.Probes["$candidate|env"] = New-Probe '{"version":"0.15.2","lib_dir":"C:\\fixture\\lib"}'
      }
      [Environment]::SetEnvironmentVariable($environmentName, $a)
    }
    function Invoke-ResolverCase {
      $result = @()
      $failure = $null
      try { $result = @(Resolve-ZigVersion "0.15.2" $environmentName) } catch { $failure = $_ }
      [pscustomobject]@{ Result = $result; Failure = $failure }
    }
    function Read-Diagnostic([int] $index = 0) {
      $line = $state.Diagnostics[$index]
      Assert-Resolver ($line.StartsWith("ZIG_RESOLVER_DIAGNOSTIC ") -and $line.Length -lt 2500) "diagnostic tag or bound"
      Assert-Resolver ($line -notmatch "ghp_PRIVATE_CANARY|userinfo|GITHUB_TOKEN") "secret canary escaped diagnostic"
      $line.Substring("ZIG_RESOLVER_DIAGNOSTIC ".Length) | ConvertFrom-Json
    }

    Reset-ResolverCase
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $a -and $null -eq $case.Failure) "success return changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$a|env" -and $state.Diagnostics.Count -eq 0) "success probes repeated or diagnosed"
    Reset-ResolverCase
    $state.Exists[$a] = $false
    $state.Probes["$b|version"] = New-Probe "0.16.0"
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $c) "fallback selection changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$b|version,$c|version,$c|env") "fallback order/deduplication/env skipping changed"
    $missing = Read-Diagnostic
    $mismatch = Read-Diagnostic 1
    Assert-Resolver (-not $missing.exists -and $null -eq $missing.version -and $missing.source -eq "configured") "missing candidate fabricated probe"
    Assert-Resolver ($mismatch.source -eq "PATH" -and $mismatch.version.observedVersion -eq "0.16.0" -and $null -eq $mismatch.env) "mismatch evidence wrong"

    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "ghp_PRIVATE_CANARY" -1073741502 "ghp_PRIVATE_CANARY"
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.version.exitCodeHex -eq "0xC0000142") "nonzero exit/fallback changed"
    Assert-Resolver ($null -eq $diagnostic.version.observedVersion -and $diagnostic.version.stderr.reason -eq "unclassified") "unsafe version or stderr surfaced"
    foreach ($envText in @("invalid ghp_PRIVATE_CANARY", '{"version":"0.15.2","lib_dir":"C:\\fixture\\absent","env":{"GITHUB_TOKEN":"ghp_PRIVATE_CANARY"}}')) {
      Reset-ResolverCase
      $state.Probes["$a|env"] = New-Probe $envText 9 "error: unable to find zig installation directory ghp_PRIVATE_CANARY"
      $case = Invoke-ResolverCase
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.reason -eq "env-exit" -and $diagnostic.env.exitCode -eq 9) "env failure selection changed"
      Assert-Resolver ($diagnostic.env.stderr.reason -eq "unable to find zig installation directory") "safe known reason missing"
      if ($envText.StartsWith("{")) {
        Assert-Resolver ($diagnostic.env.parse -eq "parsed" -and $diagnostic.env.libDirectoryPresent -eq $false) "library metadata missing"
      } else {
        Assert-Resolver ($diagnostic.env.parse -eq "metadata-unavailable") "parse metadata missing"
      }
      $state.Probes["$a|env"] = New-Probe $envText
      $state.Diagnostics.Clear()
      $case = Invoke-ResolverCase
      Assert-Resolver ($case.Result[0] -ceq $a -and $state.Diagnostics.Count -eq 0) "new JSON/lib gate was introduced"
    }

    Reset-ResolverCase
    $failure = [Management.Automation.ErrorRecord]::new(
      [Management.Automation.RuntimeException]::new("ghp_PRIVATE_CANARY",
        [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY")),
      "Launch", [Management.Automation.ErrorCategory]::OpenError, $null)
    $state.Probes["$a|version"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 1 -and $case.Failure.ToString() -notmatch "ghp_PRIVATE_CANARY") "exception changed stop behavior or exposed secret"
    Assert-Resolver ($null -eq $diagnostic.version.exitCode -and $diagnostic.version.nativeErrorCode -eq 5) "exception fabricated exit"
    Reset-ResolverCase
    $state.Probes["$a|env"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 2 -and $diagnostic.reason -eq "env-exception") "env exception did not stop after one probe"
    Assert-Resolver ($null -eq $diagnostic.env.exitCode -and $diagnostic.env.nativeErrorCode -eq 5) "env exception lost nullable exit/native code"
    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "0.16.0"
    $state.WriterFails = $true
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result[0] -ceq $b -and $state.Warnings.Count -eq 1) "writer failure changed fallback"
    $state.WarningFails = $true
    $state.Calls.Clear()
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $b -and $null -eq $case.Failure) "both writer failures changed fallback"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$b|version,$b|env") "both writer failures changed probe order"
    foreach ($candidate in @($a, $b, $c)) { $state.Exists[$candidate] = $false }
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 0 -and $case.Failure.ToString() -eq "Zig 0.15.2 is required for the pinned Windows provider; set $environmentName.") "both writer failures masked original guard"

    Reset-ResolverCase
    $nonAsciiVersion = ([string][char]0x0661) + ".2.3"
    $overLimitVersion = "1.2.3+" + ("a" * 65)
    foreach ($unsafeVersion in @($nonAsciiVersion, $overLimitVersion)) {
      foreach ($probeName in @("version", "env")) {
        $state.Diagnostics.Clear()
        $text = if ($probeName -eq "version") { $unsafeVersion } else { @{ version = $unsafeVersion } | ConvertTo-Json -Compress }
        $probe = New-Probe $text 1
        if ($probeName -eq "version") {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "version-exit" $probe $null
        } else {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "env-exit" (New-Probe "0.15.2") $probe
        }
        $diagnostic = Read-Diagnostic
        $summary = $diagnostic.$probeName
        Assert-Resolver ($null -eq $summary.observedVersion -and
          $summary.stdout.bytes -eq [Text.Encoding]::UTF8.GetByteCount($text) -and
          $summary.stdout.sha256.Length -eq 64) "non-ASCII or over-limit version was not reduced to hash/length"
        Assert-Resolver (-not $state.Diagnostics[0].Contains($unsafeVersion)) "unsafe version appeared literally"
      }
    }
    Assert-Resolver ([Text.Encoding]::UTF8.GetByteCount($overLimitVersion) -gt 64) "version size control is not over limit"
    $state.WriterFails = $false
    foreach ($candidate in @("https://userinfo@github.com/zig", "C:\ghp_PRIVATE_CANARY\zig.exe", ("C:\" + ("x" * 520)))) {
      $state.Diagnostics.Clear()
      Write-ZigResolverDiagnostic $candidate "configured" "0.15.2" $true "version-exit" (New-Probe ("ghp_PRIVATE_CANARY" * 2000) 1) $null
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($diagnostic.candidate -eq "[omitted]" -and $diagnostic.version.stdout.bytes -gt 16384) "candidate/output cap or redaction failed"
    }
  } finally {
    [Environment]::SetEnvironmentVariable($environmentName, $priorEnvironment)
    if ($null -eq $priorExit) { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    else { $global:LASTEXITCODE = $priorExitValue }
  }
}

$runner = Join-Path $PSScriptRoot "..\validate.ps1"
if (-not (Test-Path $runner)) {
  throw "RED: validation runner does not exist at $runner"
}

$tasks = & $runner -List
$expected = @(
  "swift-portable",
  "swift-contracts",
  "swift-production",
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
  "remote-bridge",
  "remote-e2e",
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy",
  "terminal-gate",
  "windows-shell",
  "packaging",
  "hardening"
)
foreach ($task in $expected) {
  if ($tasks -notcontains $task) {
    throw "Validation task '$task' is missing"
  }
}

$dryRun = & $runner -Task swift-paths -DryRun
if ($LASTEXITCODE -ne 0) {
  throw "Dry run failed with exit code $LASTEXITCODE"
}
if (($dryRun -join "`n") -notmatch "swift-paths") {
  throw "Dry run did not name the selected task"
}

# provider-build is the build-only entry point for provider cache seeding: it is
# selectable on its own but never part of -Task all (terminal-gate reuses it).
if ($tasks -notcontains "provider-build") {
  throw "RED: validation runner has no build-only provider-build task"
}
$providerDryRun = @(& $runner -Task provider-build -DryRun)
if ($LASTEXITCODE -ne 0 -or $providerDryRun.Count -ne 1 -or $providerDryRun[0] -cne "task=provider-build") {
  throw "RED: -Task provider-build does not select exactly the build-only task: $($providerDryRun -join ', ')"
}
$allDryRun = @(& $runner -Task all -DryRun)
if ($allDryRun.Count -lt 10 -or $allDryRun -contains "task=provider-build" -or $allDryRun -notcontains "task=terminal-gate") {
  throw "RED: -Task all must keep terminal-gate and exclude the build-only provider-build task: $($allDryRun -join ', ')"
}
$providerRunnerSource = Get-Content $runner -Raw
$providerClause = [regex]::Match($providerRunnerSource, '(?s)\n    "provider-build" \{(.*?)\n    \}')
if (-not $providerClause.Success -or $providerClause.Groups[1].Value -notmatch 'Invoke-ProviderBuild' -or
    $providerClause.Groups[1].Value -match '(?i)terminal-gate\.ps1|TerminalGate\.Tests|windows-shell\.ps1|uia|Stress') {
  throw "RED: provider-build task does not run only the shared build-only provider compile"
}
$terminalClause = [regex]::Match($providerRunnerSource, '(?s)\n    "terminal-gate" \{(.*?)\n    \}')
if (-not $terminalClause.Success -or
    $terminalClause.Groups[1].Value -notmatch '(?s)Invoke-ProviderBuild.*?terminal-gate\.ps1.*?-SkipProviderBuild.*?-Stress') {
  throw "RED: terminal-gate does not reuse the build-only provider compile before its full gate"
}
$providerScriptSource = Get-Content (Join-Path $PSScriptRoot "..\provider-build.ps1") -Raw -ErrorAction SilentlyContinue
foreach ($consumer in @("terminal-gate.ps1", "windows-shell.ps1")) {
  $consumerSource = Get-Content (Join-Path $PSScriptRoot "..\$consumer") -Raw
  if ($consumerSource -notmatch 'provider-build\.ps1' -or
      $consumerSource -match '-Demit-win32-host=true' -or
      $consumerSource -match '-Dtarget=x86_64-windows-gnu') {
    throw "RED: $consumer duplicates the pinned provider build instead of calling provider-build.ps1"
  }
}
if ($providerScriptSource -notmatch '-Demit-win32-host=true' -or $providerScriptSource -notmatch '-Dtarget=x86_64-windows-gnu') {
  throw "RED: provider-build.ps1 does not own the canonical provider build flags"
}

$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -File $runner -Task not-a-task *> $null
if ($LASTEXITCODE -eq 0) {
  throw "An unknown validation task succeeded"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$untrackedDirectory = Join-Path $repoRoot "investigation\spikes\validation-runner-untracked"
New-Item -ItemType Directory -Force $untrackedDirectory | Out-Null
try {
  "let value=1" | Set-Content (Join-Path $untrackedDirectory "Unformatted.swift")
  & $pwsh -NoProfile -File $runner -Task swift-format *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "An unformatted untracked Swift source was ignored"
  }
} finally {
  Remove-Item -LiteralPath $untrackedDirectory -Recurse -Force
}

$foreignJunction = Join-Path $repoRoot `
  "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\OwnershipSentinel"
New-Item -ItemType Directory -Force $foreignJunction | Out-Null
try {
  & $runner -Task swift-format -DryRun *> $null
  if (-not (Test-Path $foreignJunction)) {
    throw "A validation task removed resources owned by another task"
  }

  $windowsWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
  if ($windowsWorkflow -notmatch "(?s)full-pinned:.*bootstrap\.ps1.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment") {
    throw "RED: full-pinned Windows CI does not run real hardening after provider setup"
  }
  if ($windowsWorkflow -notmatch "GRAPHCODE_HARDENING_TARGET") {
    throw "RED: full-pinned Windows CI does not provide an owned environment harness"
  }
  $hardeningSource = Get-Content (Join-Path $PSScriptRoot "Hardening.Tests.ps1") -Raw
  foreach ($stage in @("real zmx/ConPTY terminal matrix", "real GraphCode shell matrix")) {
    if ($hardeningSource -notmatch ([regex]::Escape($stage) + ' failed \(exit=\$LASTEXITCODE; hex=')) {
      throw "Hardening stage failure omits the native exit code: $stage"
    }
  }
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
      $hardeningSource, [ref]$tokens, [ref]$errors)
    foreach ($name in @("Find-Bytes", "Get-HighOutputDiagnostics", "Get-HighOutputPayloadText")) {
      $function = $ast.Find({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true)
      if (-not $function) { throw "RED: high-output diagnostics helper is missing: $name" }
      . ([scriptblock]::Create($function.Extent.Text))
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("START" + ("A" * 1024) + "END")
    $diagnostics = Get-HighOutputDiagnostics $bytes "START" "END"
    if ($diagnostics.capturedBytes -ne $bytes.Length -or
        $diagnostics.startOffset -ne 0 -or $diagnostics.endOffset -ne 1029 -or
        $diagnostics.prefix.Length -ne 512 -or $diagnostics.suffix.Length -ne 512) {
      throw "High-output diagnostics lost marker positions or exceeded transcript bounds"
    }
    $partial = Get-HighOutputDiagnostics ([Text.Encoding]::ASCII.GetBytes("END")) "START" "END"
    if ($partial.startOffset -ne -1 -or $partial.endOffset -ne 0) {
      throw "High-output diagnostics hide an end marker when the start marker is missing"
    }
    $empty = Get-HighOutputDiagnostics ([byte[]]::new(0)) "START" "END"
    if ($empty.capturedBytes -ne 0 -or $empty.startOffset -ne -1 -or
        $empty.endOffset -ne -1 -or $empty.prefix -ne "" -or $empty.suffix -ne "") {
      throw "High-output diagnostics cannot report an empty capture"
    }
    $escape = [string][char]27
    $captures = @(
      "STARTAAAAEND",
      "ST${escape}[0mARTAA${escape}[31mAAEN${escape}[0mD",
      "STA`r`nRTAAAAE`r`nND",
      "START${escape}]0;END$([char]7)AAAAEND",
      "ST${escape}]0;title${escape}\ARTAAAAEND",
      "${escape}]0;before${escape}\STARTAAAAEND${escape}]0;after${escape}\"
    )
    foreach ($capture in $captures) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($payload -cne "AAAA") {
        throw "RED: high-output completion must survive terminal framing inside markers"
      }
    }
    foreach ($capture in @("", "STARTAAAA", "AAAAEND", "ENDSTARTAAAA",
        "${escape}]0;STARTAAAAEND")) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($null -ne $payload) { throw "Incomplete or reversed output markers were accepted" }
    }
    $emptyPayload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes("STARTEND")) "START" "END"
    if ($null -eq $emptyPayload -or $emptyPayload -cne "") {
      throw "Empty completed output must reach the length/hash checks, not look pending"
    }
  }
  if ($hardeningSource -notmatch
      '(?s)if \(-not \$completed\).*?Get-HighOutputDiagnostics.*?HARDENING_OUTPUT_DIAGNOSTICS_JSON=.*?Assert-True \$completed') {
    throw "RED: real high-output failure omits bounded transcript diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)if \(\$LASTEXITCODE -ne 0\) \{\s*\$output \| Write-Output\s*throw "hardening repeated run') {
    throw "RED: failed repeated hardening discards its child diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)\$shellVersion\s*=\s*\(& \$shell --version.*?-Version \$shellVersion') {
    throw "RED: post-release hardening does not preserve the built shell version"
  }
  $windowsShellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  $windowsPortWorkflow = Get-Content `
    (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
  $windowsCacheWarmerPath = Join-Path $repoRoot ".github\workflows\windows-cache-warmer.yml"
  if (-not (Test-Path -LiteralPath $windowsCacheWarmerPath -PathType Leaf)) {
    throw "RED: Windows CI has no main-scoped cache warmer"
  }
  $windowsCacheWarmerWorkflow = Get-Content $windowsCacheWarmerPath -Raw
  $shellJobs = Get-WorkflowJobs $windowsShellWorkflow
  $portJobs = Get-WorkflowJobs $windowsPortWorkflow
  foreach ($expected in @(
      @{ Text = $portJobs["spikes-swift"]; Job = "windows-spikes Swift"; Timeout = 45; Steps = 5 },
      @{ Text = $portJobs["spikes-other"]; Job = "windows-spikes terminal and contracts"; Timeout = 40; Steps = 6 },
      @{ Text = $shellJobs["packaging-real"]; Job = "windows-shell packaging (real products)"; Timeout = 50; Steps = 6 })) {
    if ($expected.Text -notmatch "(?m)^    timeout-minutes: $($expected.Timeout)$") {
      throw "RED: $($expected.Job) does not retain measured cold-cache headroom"
    }
    $stepTimeouts = [regex]::Matches($expected.Text, '(?m)^        timeout-minutes: \d+$').Count
    if ($stepTimeouts -lt $expected.Steps) {
      throw "RED: $($expected.Job) leaves a long-running phase without a step timeout"
    }
    if ($expected.Text -notmatch '(?s)name: Bootstrap exact Windows dependencies.*?timeout-minutes: 30') {
      throw "RED: $($expected.Job) bootstrap cap cannot cover the observed cold download and clone time"
    }
  }
  foreach ($key in @(
      "windows-zig-v1-`${{ hashFiles('Tools/windows/bootstrap.ps1') }}",
      "windows-providers-v1-`${{ hashFiles('graphcode-windows/provider-pins.json', 'Tools/windows/bootstrap.ps1') }}-emit-win32-host-x86_64-windows-gnu")) {
    if ($windowsCacheWarmerWorkflow -notmatch [regex]::Escape($key)) {
      throw "RED: Windows cache warmer does not write the exact production key: $key"
    }
  }
  if ($windowsCacheWarmerWorkflow -notmatch '(?m)^  push:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^    branches: \[main\]\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^  schedule:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^    - cron: "23 4 \* \* 1"\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^  workflow_dispatch:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?s)validate\.ps1 -Task provider-build.*?actions/cache/save@' -or
      $windowsCacheWarmerWorkflow -match 'validate\.ps1 -Task terminal-gate') {
    throw "RED: Windows cache warmer does not cover main, weekly, manual, and build-only canonical provider builds"
  }
  Test-ProviderCacheSeeding $windowsShellWorkflow $windowsCacheWarmerWorkflow
  Test-ProviderCacheSeedingMutations $windowsShellWorkflow $windowsCacheWarmerWorkflow
  Test-ProviderBuildScript $repoRoot $pwsh
  foreach ($workflow in @($windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        '(?s)if: failure\(\).*?actions/upload-artifact@.*?gu-\*.*?logs\\\*\.json') {
      throw "RED: Windows CI does not retain failed UIA sandbox diagnostics as an artifact"
    }
  }
  foreach ($workflow in @($windowsWorkflow, $windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        "compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6" -or
        $workflow -notmatch "swift-version: swift-6\.3\.3-release" -or
        $workflow -notmatch "swift-build: 6\.3\.3-RELEASE") {
      throw "RED: pinned Windows CI does not install Swift 6.3.3 without WinGet"
    }
  }
  if ($windowsShellWorkflow -notmatch "bootstrap\.ps1") {
    throw "RED: Windows shell CI does not bootstrap exact dependencies"
  }
  if ($windowsShellWorkflow -notmatch "validate\.ps1 -Task windows-shell -SkipTrayLive" -or
      $windowsPortWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "Hardening\.Tests\.ps1 -Environment -SkipTrayLive") {
    throw "RED: hosted Windows CI does not explicitly declare unsupported interactive or WSL fixtures"
  }
  if ($windowsShellWorkflow -notmatch '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 -Task windows-shell\b') {
    throw "RED: Windows shell CI does not invoke the shell task containing live UI Automation"
  }
  $runnerSource = Get-Content $runner -Raw
  if ($runnerSource -notmatch
      '(?s)WINDOWS_SHELL_PRE_UIA_PROCESS_SNAPSHOT=.*?Stop-Process -Id.*?WINDOWS_SHELL_PRE_UIA_CLEANUP=verified.*?Native UI Automation live gate') {
    throw "RED: Windows shell validation does not snapshot and reap run-owned product processes before UIA"
  }
  Test-ZigResolverDiagnostics $runnerSource
  Assert-ShellHostPrerequisite $runnerSource
  $contractCall = [regex]::Match($runnerSource,
    '(?s)& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1"\)\s*`\s*-ZigExecutable \$zig0152').Value
  if (-not $contractCall) { throw "Cannot construct the host prerequisite ordering control" }
  $earlyContracts = $runnerSource.Replace($contractCall, "").Replace(
    'Invoke-Native "Pinned Winghostty host build for App contracts"',
    $contractCall + "`n      " + 'Invoke-Native "Pinned Winghostty host build for App contracts"')
  foreach ($mutation in @(
      $runnerSource.Replace('& $zig0152 build -Demit-win32-host=true', 'Write-Output "deliberately skipped build"'),
      $runnerSource.Replace('"Pinned Winghostty host build for App contracts"', '"deliberately removed prerequisite"'),
      $earlyContracts
    )) {
    $rejected = $false
    try { Assert-ShellHostPrerequisite $mutation } catch { $rejected = $true }
    if (-not $rejected) { throw "Host prerequisite contract accepted a deliberate missing-build control" }
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Signing\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run signed catalog integrity contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Rollback\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run rollback preservation contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Standalone\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run standalone setup contracts"
  }
  foreach ($contract in @("Packaging.ScriptSigning.Tests.ps1", "Packaging.Scheduler.Tests.ps1")) {
    if ($runnerSource -notmatch ('(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?' + [regex]::Escape($contract) + '.*?Packaging\.Tests\.ps1')) {
      throw "RED: packaging validation does not run $contract"
    }
  }
  if ($runnerSource -notmatch '(?s)if \(\$PackagingPart -ne "contracts"\) \{\s*Initialize-PackagingInputs\s*& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\Packaging\.Tests\.ps1"\)') {
    throw "RED: real packaging does not rebuild its own inputs before Packaging.Tests.ps1"
  }
  Test-CiPartitionCoverage $runner $pwsh $repoRoot
  Test-ShellSectionGate $repoRoot $pwsh
  Test-CiAggregateGates $repoRoot $pwsh
  if ($runnerSource -notmatch '(?s)"terminal-gate" \{\s*& .*?ProviderPins\.Tests\.ps1.*?TerminalGate\.Tests\.ps1') {
    throw "RED: terminal validation does not run provider pin no-divergence contracts"
  }
  foreach ($source in @($runnerSource, $hardeningSource)) {
    if ($source -notmatch '-StubResponseDelayMilliseconds 150') {
      throw "RED: shell validation does not exercise delayed correlated responses"
    }
  }
  if ($runnerSource -notmatch '(?s)Pinned GraphCode Windows shell build and smoke.*?Native UI Automation live gate.*?uia-live-gate\.ps1') {
    throw "RED: Windows shell validation does not execute the UI Automation live gate"
  }
  $uiaLiveGateSource = Get-Content (Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'function Get-UiaStartupFileDiagnostic' -or
      $uiaLiveGateSource -notmatch 'RedirectStandardOutput' -or
      $uiaLiveGateSource -notmatch 'function Get-UiaPrelaunchDiagnostics' -or
      $uiaLiveGateSource -notmatch 'prelaunch-diagnostics\.json' -or
      $uiaLiveGateSource -notmatch 'startup-failure\.json') {
    throw "RED: UIA startup failure does not capture both child streams, app log, and prelaunch host diagnostics"
  }
  $prelaunchDiagnostic = $uiaLiveGateSource.LastIndexOf('Get-UiaPrelaunchDiagnostics')
  $shellLaunch = $uiaLiveGateSource.IndexOf('Start-Process -FilePath $Shell')
  if ($prelaunchDiagnostic -lt 0 -or $shellLaunch -lt 0 -or
      $prelaunchDiagnostic -gt $shellLaunch -or
      $uiaLiveGateSource -notmatch 'GetCurrentWindowStationName|WindowStation' -or
      $uiaLiveGateSource -notmatch 'GetCurrentDesktopName|DesktopName' -or
      $uiaLiveGateSource -notmatch 'desktopHeap' -or
      $uiaLiveGateSource -notmatch 'sessionId') {
    throw "RED: UIA prelaunch diagnostics omit process, desktop heap, window station, or session evidence"
  }
  if ($uiaLiveGateSource -notmatch 'function Get-UiaOwnedProcessDescendants' -or
      $uiaLiveGateSource -notmatch 'UIA_PROCESS_TREE_CLEANUP=verified') {
    throw "RED: UIA teardown does not enumerate, reap, and verify all owned descendants"
  }
  $uiaTokens = $null
  $uiaParseErrors = $null
  $uiaAst = [Management.Automation.Language.Parser]::ParseInput(
    $uiaLiveGateSource, [ref]$uiaTokens, [ref]$uiaParseErrors)
  if ($uiaParseErrors.Count -ne 0) {
    throw "RED: UIA live gate no longer parses after startup diagnostic changes"
  }
  foreach ($helperName in @(
      "Protect-UiaStartupDiagnosticText",
      "Get-UiaStartupDiagnosticValue",
      "Get-UiaStartupFileDiagnostic",
      "Get-UiaStartupImageHash",
      "Write-UiaStartupFailureDiagnostic",
      "Get-UiaPrelaunchDiagnostics",
      "Get-UiaOwnedProcessDescendants",
      "Stop-UiaOwnedProcessTrees"
    )) {
    $helper = $uiaAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $helperName
      }, $true)
    if ($null -eq $helper) { throw "RED: UIA startup capture helper is missing: $helperName" }
    . ([scriptblock]::Create($helper.Extent.Text))
  }
  $startupCapturePath = Join-Path $env:TEMP "uia-startup-capture-$PID.log"
  try {
    [IO.File]::WriteAllText($startupCapturePath, "loader failed`npassword=private-canary`n")
    $capture = Get-UiaStartupFileDiagnostic $startupCapturePath "logs\shell-stderr.log"
    if ($capture.state -ne "available" -or
        $capture.content -notmatch "loader failed" -or
        $capture.content -match "private-canary" -or
        $capture.readBytes -ne $capture.lengthBytes) {
      throw "RED: UIA startup capture does not retain bounded, redacted child output"
    }
    $truncatedCapture = Get-UiaStartupFileDiagnostic $startupCapturePath `
      "logs\shell-stderr.log" 8
    if ($truncatedCapture.state -ne "truncated" -or
        $truncatedCapture.readBytes -ne 8 -or $truncatedCapture.lengthBytes -le 8) {
      throw "RED: UIA startup capture does not bound oversized diagnostics"
    }
    $missingCapture = Get-UiaStartupFileDiagnostic `
      (Join-Path $env:TEMP "uia-missing-$PID.log") "logs\missing.log"
    if ($missingCapture.state -ne "missing") {
      throw "RED: UIA startup capture does not distinguish a missing child log"
    }
    $startupLogDirectory = Join-Path $env:TEMP "uia-startup-logs-$PID"
    $startupSupportDirectory = Join-Path $env:TEMP "uia-startup-support-$PID"
    New-Item -ItemType Directory -Path $startupLogDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $startupSupportDirectory -Force | Out-Null
    [IO.File]::WriteAllText(
      (Join-Path $startupLogDirectory "shell-stderr.log"),
      "loader failed`npassword=stderr-canary`n"
    )
    [IO.File]::WriteAllText(
      (Join-Path $startupLogDirectory "shell-stdout.log"),
      "child output captured"
    )
    [IO.File]::WriteAllText(
      (Join-Path $startupSupportDirectory "graphcode-windows.log"),
      "app initialization failed`nsecret=app-canary`n"
    )
    Write-UiaStartupFailureDiagnostic (Get-Process -Id $PID) 0 `
      $startupCapturePath $env:TEMP $startupLogDirectory $startupSupportDirectory
    $startupRecord = Get-Content -LiteralPath `
      (Join-Path $startupLogDirectory "startup-failure.json") -Raw | ConvertFrom-Json
    if ($startupRecord.stderr.content -notmatch "loader failed" -or
        $startupRecord.stdout.content -notmatch "child output captured" -or
        $startupRecord.applicationLog.content -notmatch "app initialization failed" -or
        $startupRecord.stderr.content -match "stderr-canary" -or
        $startupRecord.applicationLog.content -match "app-canary") {
      throw "RED: retained UIA startup report omits or exposes captured child and app output"
    }
  } finally {
    Remove-Item -LiteralPath (Join-Path $env:TEMP "uia-startup-logs-$PID") `
      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP "uia-startup-support-$PID") `
      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupCapturePath -Force -ErrorAction SilentlyContinue
  }
  $hostInfoClassAt = $uiaLiveGateSource.IndexOf("public static class GraphCodeUiaHostInfo")
  if ($hostInfoClassAt -lt 0) {
    throw "RED: UIA host context native diagnostics type is missing"
  }
  $hostInfoAddTypeAt = $uiaLiveGateSource.LastIndexOf(
    'Add-Type -TypeDefinition @"', $hostInfoClassAt
  )
  $hostInfoBodyAt = $uiaLiveGateSource.IndexOf("`n", $hostInfoAddTypeAt) + 1
  $hostInfoCloseAt = $uiaLiveGateSource.IndexOf('"@', $hostInfoClassAt)
  if ($hostInfoAddTypeAt -lt 0 -or $hostInfoBodyAt -le 0 -or
      $hostInfoCloseAt -lt 0) {
    throw "RED: UIA host context native diagnostics type is missing"
  }
  $hostInfoBody = $uiaLiveGateSource.Substring(
    $hostInfoBodyAt, $hostInfoCloseAt - $hostInfoBodyAt
  ).TrimEnd("`r", "`n")
  Add-Type -TypeDefinition $hostInfoBody
  $hostSessionId = [GraphCodeUiaHostInfo]::CurrentSessionId()
  if ($hostSessionId -isnot [uint32]) {
    throw "RED: UIA host context did not resolve the current Windows session"
  }
  $hostDiagnostics = Get-UiaPrelaunchDiagnostics
  if ($hostDiagnostics.sessionId.state -ne "available" -or
      $hostDiagnostics.currentProcessId -ne $PID -or
      $hostDiagnostics.desktopHeap.state -ne "usage_unavailable") {
    throw "RED: UIA host context diagnostics omitted explicit session or desktop-heap status"
  }
  $treeFixturePath = Join-Path $env:TEMP "uia-process-tree-$PID.ps1"
  $treeRoot = $null
  try {
    [IO.File]::WriteAllText($treeFixturePath, @'
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME "pwsh.exe"))
$start.ArgumentList.Add("-NoProfile")
$start.ArgumentList.Add("-Command")
$start.ArgumentList.Add("Start-Sleep -Seconds 60")
[void][Diagnostics.Process]::Start($start)
Start-Sleep -Seconds 60
'@)
    $treeRoot = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-File", $treeFixturePath) -PassThru
    $treeObserved = $false
    for ($attempt = 0; $attempt -lt 20 -and -not $treeObserved; $attempt++) {
      Start-Sleep -Milliseconds 100
      $treeObserved = @(Get-UiaOwnedProcessDescendants @($treeRoot.Id)).Count -gt 0
    }
    if (-not $treeObserved) { throw "RED: UIA owned-process traversal missed a controlled child" }
    Stop-UiaOwnedProcessTrees @($treeRoot)
    if (-not $treeRoot.HasExited) {
      throw "RED: UIA owned-process teardown returned before the controlled root exited"
    }
  } finally {
    if ($treeRoot -and -not $treeRoot.HasExited) {
      Stop-UiaOwnedProcessTrees @($treeRoot)
    }
    Remove-Item -LiteralPath $treeFixturePath -Force -ErrorAction SilentlyContinue
  }
  $pidReuseAdopted = & {
    $rootCreated = [datetime]"2026-01-01T12:00:00"
    function Get-CimInstance {
      @(
        [pscustomobject]@{ ProcessId = 624; ParentProcessId = 7416; Name = "conhost.exe"; ExecutablePath = ""; CreationDate = $rootCreated }
        [pscustomobject]@{ ProcessId = 700; ParentProcessId = 624; Name = "child.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddSeconds(5) }
        [pscustomobject]@{ ProcessId = 636; ParentProcessId = 624; Name = "csrss.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddHours(-3) }
        [pscustomobject]@{ ProcessId = 732; ParentProcessId = 636; Name = "wininit.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddHours(-2) }
      )
    }
    @(Get-UiaOwnedProcessDescendants @(624) | ForEach-Object { $_.Name })
  }
  if (($pidReuseAdopted -join ",") -ne "child.exe") {
    throw "RED: UIA owned-process traversal adopts processes older than a reused parent PID: $($pidReuseAdopted -join ',')"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_ROOT_ACCESS' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'maxSandboxRootUtf16' -or
      $uiaLiveGateSource -notmatch 'Require \(\[GraphCodeUiaGateState\]::WindowIsVisible\(\$shellWindow\)\)') {
    throw "RED: UIA gate does not identify visible shell HWND, background root access, missing modal and short TEMP remedy"
  }
  if ($uiaLiveGateSource -notmatch 'FindTopLevel\("GraphCodeUpdateOffer", \[uint32\]\$process\.Id\)' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIRECT' -or
      $uiaLiveGateSource -notmatch 'FromHandle\(\$nativeUpdateWindow\)' -or
      $uiaLiveGateSource -notmatch '\$updateDialog = \$directUpdate') {
    throw "RED: UIA gate does not use the owned modal HWND when desktop-tree lookup omits it"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_RENAME_DISPATCH' -or
      $uiaLiveGateSource -notmatch 'UIA_RENAME_INPUT' -or
      $uiaLiveGateSource -notmatch 'UIA_RENAME_OUTCOME' -or
      $uiaLiveGateSource -notmatch 'SetEditTextById' -or
      $uiaLiveGateSource -notmatch 'Native Title edit control \(id 9904\)' -or
      $uiaLiveGateSource -notmatch 'Goal summary edit control \(id 9100\)' -or
      $uiaLiveGateSource -notmatch 'Update node dialog did not open' -or
      $uiaLiveGateSource -notmatch 'Update node cancellation left the dialog open' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_NODE_SUBMIT_STATE' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_NODE_DISPATCH') {
    throw "RED: UIA gate does not verify rename dispatch/result or Edit Details open, cancel, and submit"
  }
  if ($uiaLiveGateSource -notmatch 'SendMessageString\(edit, 0x000C' -or
      $uiaLiveGateSource -notmatch 'SendMessageText\(edit, 0x000D' -or
      $uiaLiveGateSource -match '(?s)SetEditTextById\(IntPtr parent, int controlId, string text\) \{[^}]*SetWindowText\(') {
    throw "RED: UIA gate writes or reads cross-process edit text through the window caption instead of WM_SETTEXT/WM_GETTEXT"
  }
  if ($uiaLiveGateSource -notmatch 'function Read-DaemonCommandLog' -or
      $uiaLiveGateSource -notmatch '\[IO\.FileShare\]::ReadWrite -bor \[IO\.FileShare\]::Delete' -or
      $uiaLiveGateSource -match 'ReadAllText\(\$daemonCommandLogPath\)') {
    throw "RED: UIA gate reads the daemon command log without tolerating the recorder's open write handle"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_DAEMON_MODEL' -or
      $uiaLiveGateSource -notmatch '-ApplyGraphCommands' -or
      $uiaLiveGateSource -notmatch 'Remove-Item Env:GRAPHCODE_UIA_CONNECTION_FAILURE' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION_CONFIRMED' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION_UNCONFIRMED' -or
      $uiaLiveGateSource -notmatch 'rename stub daemon never applied the dispatched rename') {
    throw "RED: UIA gate never observes a rename result returned by a connected daemon"
  }
  # The connected-daemon graph-card/sidebar propagation outcome is intentionally
  # non-blocking (proven intermittent by repeated CI evidence; see
  # investigation/ui-parity-matrix.md, Node update/rename row): the gate must log
  # UIA_CONNECTED_RENAME_PROPAGATION_CONFIRMED or _UNCONFIRMED on every run
  # instead of throwing on a mismatch, so a known-flaky, unresolved render-path
  # gap never blocks CI while still surfacing honest evidence either way.
  if ($uiaLiveGateSource -match '(?s)Require \(\$renameLiveGraphTitle -eq \$renameFinalTitle\)' -or
      $uiaLiveGateSource -match '(?s)Require \(\$renameLiveSidebarTitle -eq \$renameFinalTitle\)') {
    throw "RED: UIA gate throws on the known-intermittent graph card/sidebar propagation outcome instead of logging it"
  }
  if ($uiaLiveGateSource -notmatch '\$env:GRAPHCODE_UIA_CONNECTION_FAILURE = "1"' -or
      $uiaLiveGateSource -notmatch '(?s)\$connectionFailureBannerEvidence = \[ordered\]@\{\s*name = \[string\]\$connectionAlert\.Current\.Name' -or
      $uiaLiveGateSource -notmatch 'Write-Host \("UIA_CONNECTION_FAILURE_BANNER_EVIDENCE="' -or
      $uiaLiveGateSource -notmatch 'connectionFailureBanner = \$connectionFailureBannerEvidence') {
    throw "RED: UIA gate no longer exercises the forced disconnected connection-failure path or reports the banner it observed"
  }
  $stubDaemonSource = Get-Content (Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1") -Raw
  if ($stubDaemonSource -notmatch '\$ApplyGraphCommands' -or
      $stubDaemonSource -notmatch '\$frame\.command\.graphCommand\.command\.renameNode' -or
      $stubDaemonSource -notmatch 'appliedRenames' -or
      $stubDaemonSource -notmatch 'function New-StubGraphEvent') {
    throw "RED: stub daemon cannot apply a renameNode command and republish its graph"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$updateDialog = \$desktop\.FindFirst\(\s*\[System\.Windows\.Automation\.TreeScope\]::Children' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_CHILDREN found=' -or
      $uiaLiveGateSource -notmatch 'Current\.ProcessId -ne \$process\.Id') {
    throw "RED: UIA gate does not search top-level dialogs as desktop children scoped to the shell PID"
  }
  if ($uiaLiveGateSource -notmatch 'LastActivationDiagnostic' -or
      $uiaLiveGateSource -notmatch 'SetForegroundWindow\(window\).*?Marshal.GetLastWin32Error\(\)' -or
      $uiaLiveGateSource -notmatch 'AttachThreadInput\(currentThread, targetThread, true\).*?Marshal.GetLastWin32Error\(\)') {
    throw "RED: UIA foreground failure hides native return values and last-error diagnostics"
  }
  if ($uiaLiveGateSource -notmatch 'AttachThreadInput' -or
  $uiaLiveGateSource -notmatch 'keybd_event\(0x12, 0, 0, UIntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch 'SetActiveWindow\(window\)' -or
  $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x0101, \(UIntPtr\)key, IntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch '\[DllImport\("kernel32\.dll"\)\]\s*private static extern uint GetCurrentThreadId' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOCUS_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch '(?s)function Hide-TestProviderZmxWindows.*?\[string\]\$_\.ExecutablePath\)\s+-eq\s+\$providerZmx.*?HideProcessWindows.*?HideWindow\(\$foreground\)' -or
      $uiaLiveGateSource -notmatch 'function Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Test-FocusedElementIdentity \$candidate \$element \$expectedAutomationId' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch '\$element\.SetFocus\(\)' -or
      $uiaLiveGateSource -notmatch 'Retain-FocusWithRetry \$shellWindow \$safeFocusRow \$safeRowId "before-retention"' -or
      $uiaLiveGateSource -notmatch '\$backendFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings backend control could not retain foreground focus' -or
      $uiaLiveGateSource -notmatch '\$cancelFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings model control could not retain foreground focus') {
    throw "RED: UIA live gate does not prove foreground ownership before accepting row focus"
  }
  if ($uiaLiveGateSource -notmatch 'function Wait-ForDesktopElement' -or
      $uiaLiveGateSource -notmatch 'function Wait-ForDesktopElementGone' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'empty global New Loop node form' -or
      $uiaLiveGateSource -notmatch 'empty project New Loop node form' -or
      $uiaLiveGateSource -notmatch 'project-row New Loop node form' -or
      $uiaLiveGateSource -notmatch 'Open Folder picker close') {
    throw "RED: UIA live gate does not wait deterministically for asynchronous modal windows"
  }
  if ($uiaLiveGateSource -match '(?s)New Loop command was rejected.*?for \(\$index = 0; \$index -lt 40 -and \$null -eq \$.*NodeForm' -or
      $uiaLiveGateSource -match '(?s)Open Folder command was rejected.*?Start-Sleep -Milliseconds 200\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)') {
    throw "RED: UIA live gate reintroduced short fixed polling around New Loop modal commands"
  }
  if ($uiaLiveGateSource -notmatch 'function Ensure-ShellForeground' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)\s*[\r\n]+\s*\$acquired = \$activated -and \[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOREGROUND_DIAGNOSTICS phase=\$label \$\(Get-FocusDiagnostics \$window\)' -or
      $uiaLiveGateSource -notmatch '(?s)function Ensure-ShellForeground\(.*?if \(\[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)\) \{\s*[\r\n]+\s*return \$true\s*[\r\n]+\s*\}') {
    throw "RED: UIA live gate does not reacquire GraphCode shell foreground within a bounded deadline before command paths, or performs the invasive Alt-tap activation even when already foreground"
  }
  if ($uiaLiveGateSource -notmatch '(?s)function Wait-ForDesktopElement\(.*?\[switch\] \$RecoverForeground.*?\$remainingMilliseconds = \[Math\]::Max\(.*?\$recoveryTimeout = \[Math\]::Min\(1000, \$remainingMilliseconds\).*?UIA_WAIT_FOREGROUND_RECOVERY label=\$label.*?Ensure-ShellForeground.*?-TimeoutMilliseconds \$recoveryTimeout' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS label=\$label foregroundRecoveries=\$foregroundRecoveries' -or
      $uiaLiveGateSource -notmatch '(?s)-label "project-row New Loop node form".*?-RecoverForeground' -or
      $uiaLiveGateSource -notmatch '(?s)-label "empty global New Loop node form".*?-RecoverForeground' -or
      $uiaLiveGateSource -notmatch '(?s)-label "empty project New Loop node form".*?-RecoverForeground') {
    throw "RED: UIA modal waits do not boundedly reacquire foreground after a post-command foreground loss"
  }
  if ($uiaLiveGateSource -notmatch '(?s)Require \(\$null -ne \$projectNewLoop\) "project row omitted New Loop"\s*[\r\n]+\s*Require \(Ensure-ShellForeground \$shellWindow "project-row New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before invoking project-row New Loop"\s*[\r\n]+\s*\$projectNewLoop\.GetCurrentPattern' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty global New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty global New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty global New Loop command was rejected"' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty project New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty project New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty project New Loop command was rejected"') {
    throw "RED: UIA live gate New Loop invocation is not preceded by verified foreground recovery at every site"
  }
  $shellTests = Get-Content (Join-Path $PSScriptRoot "WindowsShell.Tests.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'function Wait-ForPopupMenu' -or
      $uiaLiveGateSource -notmatch 'function Get-PopupMenuItems' -or
      $uiaLiveGateSource -notmatch 'function Close-PopupMenu' -or
      $uiaLiveGateSource -notmatch 'FindPopupMenuWindow' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(popup, 0x01E1, UIntPtr\.Zero, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x802C, \(UIntPtr\)target, IntPtr\.Zero\)') {
    throw "RED: UIA live gate cannot open, read, or dismiss a native TrackPopupMenu popup"
  }
  if ($uiaLiveGateSource -notmatch '\$moveProjectMenuText = "Move Project\.\.\. \(unavailable: daemon support required\)"' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 1\).*?Wait-ForPopupMenu \$process \$shellWindow "project"' -or
      $uiaLiveGateSource -notmatch 'Require \(-not \$moveProjectItem\.Enabled\)' -or
      $uiaLiveGateSource -notmatch '\$moveProjectItem\.Text -eq \$moveProjectMenuText' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 2\).*?\$_\.Id -in @\(5149, 5151, 5144\)' -or
      $uiaLiveGateSource -notmatch 'project context menu did not dismiss, leaving the shell blocked in its modal loop') {
    throw "RED: UIA live gate does not assert the live project context menu's disabled Move item and deterministic dismissal"
  }
  if ($shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\GraphContextMenu\.zig' -or
      $shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\MainWindow\.zig') {
    throw "RED: Windows shell validation does not run the context menu and gate fixture message tests"
  }
  $appSource = Get-Content (Join-Path $repoRoot "graphcode-windows\src\App.zig") -Raw
  if ($appSource -notmatch 'fn showUiaContextMenu' -or
      $appSource -notmatch 'MainWindow\.wm_uia_context_menu => \{' -or
      $appSource -notmatch '(?s)wparam == MainWindow\.menu_watchdog_timer_id.*?c\.EndMenu\(\)') {
    throw "RED: the shell cannot open a gate-requested context menu, or an abandoned popup can block its message loop forever"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_CANVAS_CONTEXT_MENU_EVIDENCE' -or
      $uiaLiveGateSource -notmatch '\$canvasContextMenuEvidence' -or
      $uiaLiveGateSource -notmatch 'canvasContextMenu = \$canvasContextMenuEvidence' -or
      $uiaLiveGateSource -notmatch '"canvas background"' -or
      $uiaLiveGateSource -notmatch '"canvas node"' -or
      $uiaLiveGateSource -notmatch '"canvas edge"' -or
      $uiaLiveGateSource -notmatch '(?s)Find-FragmentByIdWithRetry \$root "actual-size" \$rawWalker.*?\.Invoke\(\).*?\$graph = Find-FragmentByIdWithRetry \$root "graph" \$rawWalker.*?\$canvasContextCards' -or
      $uiaLiveGateSource -notmatch 'canvas \$\(\$probe\.Label\) context menu point .*? is outside live graph bounds' -or
      $uiaLiveGateSource -notmatch 'BoundingRectangle' -or
      $uiaLiveGateSource -notmatch 'PostRightClickAt\(\$ownerWindow' -or
      $uiaLiveGateSource -notmatch 'PostRightClickAt\(\$shellWindow' -or
      $uiaLiveGateSource -notmatch 'PopupMenuItemState' -or
      $uiaLiveGateSource -notmatch 'Checked\s+=\s+\(\(\$state -band 0x8\) -ne 0\)' -or
      $uiaLiveGateSource -notmatch 'function ConvertTo-PopupMenuEvidence' -or
      $uiaLiveGateSource -notmatch 'checked = \$_.Checked' -or
      $uiaLiveGateSource -notmatch 'state = \$_.State' -or
      $uiaLiveGateSource -notmatch 'Close-PopupMenu' -or
      $uiaLiveGateSource -notmatch 'GetMenuItemRect' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch 'SetCursorPos' -or
      $uiaLiveGateSource -notmatch 'GetCursorPos' -or
      $uiaLiveGateSource -notmatch 'SendInput' -or
      $uiaLiveGateSource -notmatch 'cursorBefore = @\(\$editEdgeClick\.CursorBeforeX' -or
      $uiaLiveGateSource -notmatch 'hilite = \$editEdgeClick\.Hilite' -or
      $uiaLiveGateSource -notmatch 'actionPopupClosed = \$edgePopupClosed' -or
      $uiaLiveGateSource -notmatch 'UIA_CANVAS_EDGE_ACTION_CLICK_EVIDENCE' -or
      $uiaLiveGateSource -notmatch 'actionClick = \$editEdgeClickEvidence' -or
      $uiaLiveGateSource -notmatch 'NameProperty, "Edit edge"' -or
      $uiaLiveGateSource -notmatch 'Create or edit edge' -or
      $uiaLiveGateSource -notmatch 'editActionDialogOpened = \$canvasEdgeEditDialogOpened' -or
      $uiaLiveGateSource -notmatch 'daemonCommandUnchanged = \$canvasEdgeDaemonCommandUnchanged' -or
      $uiaLiveGateSource -notmatch 'UIA loop A|UIA loop B') {
    throw "RED: UIA live gate does not measure blank-canvas, node-card, and edge context menus from live geometry"
  }
  if ($uiaLiveGateSource -notmatch '(?s)canvasContextMenu = \$canvasContextMenuEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress') {
    throw "RED: UIA final summary loses nested canvas menu items and edge action measurements"
  }
  if ($stubDaemonSource -notmatch '\$frame\.command\.graphCommand\.command\.createNode\._0' -or
      $stubDaemonSource -notmatch 'appliedCreates' -or
      $stubDaemonSource -notmatch '\$nodeLoopTypes\[\$id\]' -or
      $stubDaemonSource -notmatch '(?s)function Write-StubResultFile.*?for \(\$attempt = 0; \$attempt -lt 40; \$attempt\+\+\).*?Set-Content -LiteralPath \$path -Value \$json -NoNewline -ErrorAction Stop.*?catch \[IO\.IOException\].*?Start-Sleep -Milliseconds 25' -or
      $stubDaemonSource -notmatch '\$null = Write-StubResultFile \$ResultPath \$json' -or
      $stubDaemonSource -notmatch 'if \(\$renameApplied -or \$createApplied -or \$edgeApplied(?: -or \$promotionApplied)?\)') {
    throw "RED: stub daemon cannot apply exactly the createNode it received and republish the created loop type"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_SHEET_EVIDENCE' -or
      $uiaLiveGateSource -notmatch '\$nodeCreationSheetEvidence = \[ordered\]@\{' -or
      $uiaLiveGateSource -notmatch 'ClickScreenPoint' -or
      $uiaLiveGateSource -notmatch 'VisibleChildIds\(' -or
      $uiaLiveGateSource -notmatch '9600 \+ \$tileIndex' -or
      $uiaLiveGateSource -notmatch 'Say what done looks like and use positive timing values\.' -or
      $uiaLiveGateSource -notmatch 'Say what to do each time to continue\.' -or
      $uiaLiveGateSource -notmatch 'commandLogUnchanged = ' -or
      $uiaLiveGateSource -notmatch 'reasonClearedOnTypeChange = ' -or
      $uiaLiveGateSource -notmatch 'SendKeyInput\(' -or
      $uiaLiveGateSource -notmatch 'ComboSelection\(' -or
      $uiaLiveGateSource -notmatch 'graphCommand\.command\.createNode\._0' -or
      $uiaLiveGateSource -notmatch 'node creation dispatched modelTier' -or
      $uiaLiveGateSource -notmatch 'appliedCreates' -or
      $uiaLiveGateSource -notmatch 'afterTileClick = ' -or
      $uiaLiveGateSource -notmatch 'afterEdit = ' -or
      $uiaLiveGateSource -notmatch 'renderedSidebarCount -gt 0' -or
      $uiaLiveGateSource -notmatch 'renderedCardCount -gt 0') {
    throw "RED: UIA live gate does not drive the node creation sheet through conditional fields, rejected input, and a daemon-rendered create"
  }
  if ($uiaLiveGateSource -notmatch '(?s)nodeCreationSheet = \$nodeCreationSheetEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress') {
    throw "RED: UIA final summary omits the parsable node creation sheet evidence"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_SKETCH_CUSTODY_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch '(?s)sketchCustody = \$sketchCustodyEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress' -or
      $uiaLiveGateSource -notmatch 'promotion\.goal' -or
      $uiaLiveGateSource -notmatch 'promotion\.turn' -or
      $uiaLiveGateSource -notmatch 'promotion\.timed' -or
      $uiaLiveGateSource -notmatch 'createdBy' -or
      $uiaLiveGateSource -notmatch 'commandLogBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'appliedPromotions' -or
      $uiaLiveGateSource -notmatch 'appliedPromotionRequests' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch 'IsControlOwnedBy' -or
      $uiaLiveGateSource -notmatch 'TypeEditTextById' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText' -or
      $uiaLiveGateSource -notmatch 'renderedHitTests' -or
      $uiaLiveGateSource -notmatch 'function ConvertTo-SketchCanonicalJson' -or
      $uiaLiveGateSource -notmatch 'function Test-SketchPromotionReceipt' -or
      $uiaLiveGateSource -notmatch 'Test-SketchPromotionReceipt \$after \$request \$expectedWire' -or
      $uiaLiveGateSource -notmatch 'receivedWireRaw = \$receivedWireRaw' -or
      $uiaLiveGateSource -notmatch '\$custodyFirstInstruction = Sketch-Field 9104' -or
      $uiaLiveGateSource -notmatch 'instructionUnchanged = \(\$custodySubmitFields\.firstInstruction -ceq \$custodyFirstInstruction\)' -or
      $stubDaemonSource -notmatch 'appliedPromotions' -or
      $stubDaemonSource -notmatch 'appliedPromotionRequests' -or
      $stubDaemonSource -notmatch 'promoteNode' -or
      $stubDaemonSource -notmatch 'createdBy') {
    throw "RED: UIA gate does not prove all sketch promotions and custody child through native interaction, correlated wire, no mutation and rendered hit tests"
  }
  $uiaLiveGateType = [regex]::Match(
    $uiaLiveGateSource, '(?s)Add-Type -TypeDefinition @"\s*(?<source>.*?)\r?\n"@'
  )
  if (-not $uiaLiveGateType.Success) {
    throw "RED: UIA gate embedded C# type source is missing"
  }
  $uiaGateSource = $uiaLiveGateType.Groups[1].Value
  $uiaGateDefinedMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($member in [regex]::Matches(
      $uiaGateSource,
      '(?m)^\s*public\s+(?:(?:static|volatile|readonly)\s+)*(?:[\w<>\[\],.?]+\s+)+(?<member>[\w]+)\s*(?:\(|[;=])')) {
    [void]$uiaGateDefinedMembers.Add($member.Groups["member"].Value)
  }
  $uiaGateMissingMembers = @(
    [regex]::Matches($uiaLiveGateSource, '\[GraphCodeUiaGateState\]::(?<member>[\w]+)') |
      ForEach-Object { $_.Groups["member"].Value } |
      Sort-Object -Unique |
      Where-Object { -not $uiaGateDefinedMembers.Contains($_) }
  )
  if ($uiaGateMissingMembers.Count -gt 0) {
    throw "RED: UIA gate calls undefined embedded C# member(s): $($uiaGateMissingMembers -join ', ')"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_EDGE_WORKFLOW_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch '(?s)edgeWorkflow = \$edgeWorkflowEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress' -or
      $uiaLiveGateSource -notmatch 'createEdge' -or
      $uiaLiveGateSource -notmatch 'updateEdge' -or
      $uiaLiveGateSource -notmatch 'Enter the template or script that should carry context\.' -or
      $uiaLiveGateSource -notmatch 'WindowIsVisible\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeCreates' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeUpdates' -or
      $uiaLiveGateSource -notmatch 'commandLogBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'renderedEdgeId' -or
      $uiaLiveGateSource -notmatch 'graphCommandsBefore' -or
      $uiaLiveGateSource -notmatch 'graphCommandsAfter') {
    throw "RED: UIA live gate does not prove the native edge create/edit round trip and no-mutation paths"
  }
  if ($uiaLiveGateSource -notmatch 'FindVisibleProcessWindow\(\[uint32\]\$renameProcess\.Id, \$title\)' -or
      $uiaLiveGateSource -notmatch 'WindowIsVisible\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_MODAL_CENSUS' -or
      $uiaLiveGateSource -notmatch '\$delta = \$index - \[int\]\(\$after\.Split\("\|"\)\[0\]\)' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_COMBO id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch 'Require \(\$after -eq "\$index\|\$expected"\)' -or
      $uiaLiveGateSource -match '\$Matches\[1\] -in @\(') {
    throw "RED: UIA edge retry/modal/identity proof regressed"
  }
  if ($uiaLiveGateSource -notmatch 'function Edge-TypeText\(' -or
      $uiaLiveGateSource -notmatch 'Edge-TypeText \$field\.Id \$field\.Text' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_TEXT_STABLE id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::TypeEditTextById\(\$edgeWorkflowWindow, \$id, \$text\)' -or
      $uiaLiveGateSource -notmatch 'Require \(\$stable -and \$after -ceq \$text\)' -or
      $uiaLiveGateSource -notmatch 'IsControlOwnedBy\(\$edgeWorkflowWindow, \$control, \$id\)' -or
      $uiaLiveGateSource -notmatch 'HasVisibleBounds\(\$control\)' -or
      $uiaLiveGateSource -notmatch 'FocusedControlInDialog\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'WindowProcessId\(\$edgeWorkflowWindow\) -eq \$renameProcess\.Id' -or
      $uiaLiveGateSource -notmatch 'WindowTextOf\(\$edgeWorkflowWindow\) -eq \$script:edgeWorkflowTitle' -or
      $uiaLiveGateSource -notmatch 'VirtualKey = 0x2E' -or
      $uiaLiveGateSource -notmatch 'SendMessageText\(edit, 0x000D' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(edit, 0x00B1, UIntPtr\.Zero, new IntPtr\(-1\)\)' -or
      $uiaLiveGateSource -notmatch '(?s)var clear = new KeyInputRecord\[2\].*?EditBufferText\(edit\).*?var records = new KeyInputRecord\[text\.Length \* 2\]' -or
      $uiaLiveGateSource -notmatch 'for \(\$stableRetry = 0; \$stableRetry -lt 10' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_TEXT_STABLE id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch '\$renameProcess\.WaitForInputIdle\(1000\)' -or
      $uiaLiveGateSource -notmatch 'function Read-EdgeStableText\(' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_SUBMIT_FIELD name=\$label id=\$id' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9105 "payload"' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9106 "cycle guard until"' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9107 "cycle guard max"' -or
      $uiaLiveGateSource -notmatch 'LastEditClearExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditClearSent' -or
      $uiaLiveGateSource -notmatch 'LastEditTextExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditTextSent' -or
      $uiaLiveGateSource -notmatch 'LastEditClearSent = SendKeyInputs\(LastEditClearExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditTextSent = SendKeyInputs\(LastEditTextExpected' -or
      $uiaLiveGateSource -notmatch 'Require \(\$inputCountsFull\)' -or
      $uiaLiveGateSource -notmatch 'clearSent=\$clearSent/\$clearExpected textSent=\$textSent/\$textExpected' -or
      $uiaLiveGateSource -notmatch 'for \(\$attempt = 1; \$attempt -le 5' -or
      $uiaLiveGateSource -notmatch 'for \(\$layoutRetry = 0; \$layoutRetry -lt 20') {
    throw "RED: edge native text entry lacks native ownership, live layout, focus, clear/retype, or exact verification"
  }
  if ($uiaLiveGateSource -notmatch 'Open-EdgeMenu \$false 5120' -or
      $uiaLiveGateSource -notmatch 'Open-EdgeMenu \$true 5110' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9100 0' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9101 1' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9102 0' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9103 2 "Only after failure"' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9103 1 "Only after success"' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9104 1 "Apply a text template"' -or
      $uiaLiveGateSource -notmatch 'Edge-TypeText \$field\.Id \$field\.Text' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "invalid edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "valid edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "update edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 2 "cancel changed edge"' -or
      $uiaLiveGateSource -notmatch 'Assert-EdgePrefill "2\|Only after failure"' -or
      $uiaLiveGateSource -notmatch 'Assert-EdgePrefill "1\|Only after success"' -or
      $uiaLiveGateSource -notmatch 'Get-DirectChildren \$graph \$rawWalker' -or
      $uiaLiveGateSource -notmatch 'edgeCreateWire\.command\.createEdge\.from' -or
      $uiaLiveGateSource -notmatch 'edgeChange\.expectedSpec\.condition -eq "onFailure"' -or
      $uiaLiveGateSource -notmatch 'edgeChange\.spec\.condition -eq "onSuccess"' -or
      $uiaLiveGateSource -notmatch 'edgeCancelBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeUpdateRequests' -or
      $stubDaemonSource -notmatch 'appliedEdgeCreateRequests' -or
      $stubDaemonSource -notmatch 'appliedEdgeUpdateRequests' -or
      $stubDaemonSource -notmatch 'if \(\$renameApplied -or \$createApplied -or \$edgeApplied(?: -or \$promotionApplied)?\)') {
    throw "RED: edge workflow does not pin native input, exact CAS wire, correlated application, and stable rendered identity"
  }
  $nativeFormsSource = Get-Content (Join-Path $repoRoot "graphcode-windows\src\NativeForms.zig") -Raw
  if ($nativeFormsSource -notmatch '(?s)const node_labels = \[_\]\[\]const u8\{(.*?)\};') {
    throw "RED: NativeForms.zig node_labels table not found for node creation sheet label contract"
  }
  $nativeNodeLabels = @([regex]::Matches($Matches[1], '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
  $gateAst = [System.Management.Automation.Language.Parser]::ParseInput($uiaLiveGateSource, [ref]$null, [ref]$null)
  $labelMapAst = $gateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$nodeSheetFieldLabels'
    }, $true)
  $labelHashAst = if ($labelMapAst) { $labelMapAst.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true) }
  if (-not $labelHashAst) {
    throw "RED: UIA live gate node creation sheet label map is missing"
  }
  $gateLabelMap = [System.Management.Automation.ScriptBlock]::Create($labelMapAst.Right.Extent.Text).InvokeReturnAsIs()
  foreach ($labelId in @(9100, 9102, 9103, 9104, 9106, 9107, 9108, 9109, 9110, 9111, 9112, 9113, 9114)) {
    $expectedLabel = $nativeNodeLabels[$labelId - 9100]
    $actualLabel = [string]$gateLabelMap[$labelId]
    if ([string]::IsNullOrWhiteSpace($expectedLabel) -or $actualLabel -ne $expectedLabel) {
      throw "RED: UIA live gate node creation sheet label lookup for $labelId returned '$actualLabel', expected '$expectedLabel' from NativeForms.zig"
    }
  }
  if ($uiaLiveGateSource -notmatch 'expected label list is empty or blank') {
    throw "RED: UIA live gate node creation sheet label comparison can pass vacuously on an empty expected list"
  }
  if ($uiaLiveGateSource -notmatch '(?s)for \(\$index = 0; \$index -lt 20 -and\s*\[GraphCodeUiaGateState\]::FocusSourceAutomationId -ne \$safeRowId; \$index\+\+\)' -or
      $uiaLiveGateSource -notmatch 'Require \(\[GraphCodeUiaGateState\]::FocusSourceAutomationId -eq \$safeRowId\) "FocusChanged source identity changed"') {
    throw "RED: UIA focus retention waits for any FocusChanged event instead of the focused row identity"
  }
  if ($uiaLiveGateSource -notmatch 'SystemParametersInfoRect\(0x0030' -or
      $uiaLiveGateSource -notmatch 'HitTarget = !visibleEmpty && sameTopLevel && realChild == target' -or
      $uiaLiveGateSource -notmatch 'RealChildWindowFromPoint\(dialog, clientPoint\)' -or
      $uiaLiveGateSource -notmatch 'Require \(-not \$hit\.VisibleEmpty\)' -or
      $uiaLiveGateSource -notmatch 'has no visible portion inside' -or
      $uiaLiveGateSource -notmatch 'footerOccludedByTaskbar = ' -or
      $uiaLiveGateSource -notmatch 'overlapPixels = ' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_OCCLUSION') {
    throw "RED: UIA live gate node creation sheet cannot measure and record controls occluded outside the monitor work area"
  }
  if ($uiaLiveGateSource -notmatch 'if \(!hit\.HitTarget && !visibleEmpty && dialog != IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'for \(int row = 1; row <= 3; row\+\+\)' -or
      $uiaLiveGateSource -notmatch 'for \(int column = 1; column <= 5; column\+\+\)' -or
      $uiaLiveGateSource -notmatch 'return RealChildWindowFromPoint\(dialog, clientPoint\) == target;' -or
      $uiaLiveGateSource -notmatch '\} else if \(!hit\.HitTarget\) \{' -or
      $uiaLiveGateSource -notmatch 'footerOccludedByContent = ' -or
      $uiaLiveGateSource -notmatch 'coveredFraction = ' -or
      $uiaLiveGateSource -notmatch 'createCentreClicks = ' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_CONTENT_OCCLUSION' -or
      $uiaLiveGateSource -notmatch 'has no verified uncovered point in' -or
      $uiaLiveGateSource -notmatch 'SubtractCoveredRectangles' -or
      $uiaLiveGateSource -notmatch 'GetWindow\(target, 3\)' -or
      $uiaLiveGateSource -notmatch 'ChosenUncoveredRectangle = piece' -or
      $uiaLiveGateSource -notmatch 'uncoveredRectangles = ') {
    throw "RED: UIA live gate node creation sheet cannot click and record a footer control partly covered by scrolled content"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_INVALID_WINDOW' -or
      $uiaLiveGateSource -notmatch '\$nativeVisible = \[GraphCodeUiaGateState\]::WindowIsVisible\(\$nodeSheetWindow\)' -or
      $uiaLiveGateSource -notmatch '\$stillOpen = \$nativeVisible -and \$nativeTitle -eq \$nodeSheetTitle' -or
      $uiaLiveGateSource -notmatch 'Require \$stillOpen') {
    throw "RED: UIA live gate does not check the native modal remains visible after rejected Create"
  }
  if ($uiaLiveGateSource -notmatch '(?s)for \(\$attempt = 1; \$attempt -le 10; \$attempt\+\+\).*?uiaRecoveredAtAttempt = \$attempt' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_INVALID_WINDOW' -or
      $uiaLiveGateSource -notmatch 'Require \$nodeSheetClosed' -or
      $uiaLiveGateSource -notmatch 'if \(-not \[GraphCodeUiaGateState\]::WindowIsVisible\(\$nodeSheetWindow\) -or' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_FOOTER_CLICK' -or
      $uiaLiveGateSource -notmatch 'sub-3px verified uncovered strip') {
    throw "RED: UIA live gate omits modal liveness retry, native closure, or footer-click geometry"
  }
  if ($uiaLiveGateSource -notmatch 'mouseSubmitUnavailable = ' -or
      $uiaLiveGateSource -notmatch '\$allowOccludedEnter -and -not \$hit\.HitTarget -and \$hit\.ScannedPoints -gt 0' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$nodeSheetWindow\)' -or
      $uiaLiveGateSource -notmatch 'FocusControl\(\$nodeSheetWindow, \$goalEdit\)' -or
      $uiaLiveGateSource -notmatch 'SendKeyInput\(0x0D, 1\)' -or
      $uiaLiveGateSource -notmatch 'Invoke-NodeSheetClick 1 "Create \(\$loopType, invalid\)" -allowOccludedEnter:\(\$loopType -eq "goalBased"\)') {
    throw "RED: occluded Goal Create cannot submit with a measured, focused native Enter fallback"
  }
  if ($uiaLiveGateSource -notmatch '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@ -ReferencedAssemblies @\(') {
    throw "RED: UIA live gate native input helper is missing"
  }
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -TypeDefinition $Matches[1] -ReferencedAssemblies @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.AutomationEventArgs].Assembly.Location
  )
  $goalCover = [int[][]]::new(1)
  $goalCover[0] = [int[]]@(84, 699, 763, 721)
  $goalRemainder = [GraphCodeUiaGateState]::SubtractCoveredRectangles(
    [int[]]@(667, 698, 763, 728), $goalCover)
  if ($goalRemainder.Count -ne 2 -or
      ($goalRemainder[0] -join ',') -ne '667,721,763,728') {
    throw "RED: node sheet rectangle subtraction misses the real seven-pixel uncovered Create band"
  }
  $twoCovers = [int[][]]::new(2)
  $twoCovers[0] = [int[]]@(84, 699, 763, 721)
  $twoCovers[1] = [int[]]@(667, 721, 715, 728)
  $twoRemainders = [GraphCodeUiaGateState]::SubtractCoveredRectangles(
    [int[]]@(667, 698, 763, 728), $twoCovers)
  if ($twoRemainders.Count -ne 2 -or
      ($twoRemainders[0] -join ',') -ne '715,721,763,728') {
    throw "RED: node sheet rectangle subtraction does not handle more than one covering control"
  }
  if ($shellTests -notmatch '(?s)Windows update feed executable tests.*?zig test src\\WindowsUpdates\.zig.*?-lwinhttp') {
    throw "RED: Windows shell validation does not run the native updater tests"
  }
  if ($runnerSource -notmatch '\$SkipWslRemoteE2E' -or
      $runnerSource -notmatch '"--skip-local-wsl"') {
    throw "RED: hosted validation cannot explicitly isolate unavailable local WSL fixtures"
  }
  $privacyRaceSource = Get-Content `
    (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1") -Raw
  if ($privacyRaceSource -notmatch '\$AvailableProcessorCount = \[Environment\]::ProcessorCount' -or
      $privacyRaceSource -notmatch '\$remoteProcessCount = 1' -or
      $privacyRaceSource -notmatch '\[Math\]::Min\(24, \[Math\]::Max\(4, \$processorCount \* 2\)\)' -or
      $privacyRaceSource -notmatch 'GRAPHCODE_REMOTE_BRIDGE_TEST_TIMEOUT_MULTIPLIER = "3"') {
    throw "RED: remote bridge privacy race does not scale bounded concurrency to runner capacity"
  }
  if ($windowsWorkflow -notmatch "(?s)environment:.*Hardening\.Tests\.ps1 -Environment -SchemaOnly") {
    throw "RED: environment CI does not invoke the exact schema-only hardening contract"
  }
  $macWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\macos-shared-regression.yml") -Raw
  if ($macWorkflow -notmatch "brew install mise" -or
      $macWorkflow -notmatch "mise install" -or
      $macWorkflow -notmatch "mise exec -- make test") {
    throw "RED: macOS CI does not install and execute pinned mise.toml tools"
  }
  $requiredWorkflows = [ordered]@{
    "macos-shared-regression.yml" = $macWorkflow
    "windows-shell.yml" = $windowsShellWorkflow
    "windows-port-validation.yml" = $windowsPortWorkflow
    "windows-hardening.yml" = $windowsWorkflow
  }
  foreach ($entry in $requiredWorkflows.GetEnumerator()) {
    $trigger = [regex]::Match(
      $entry.Value,
      '(?ms)^  pull_request:(?<settings>.*?)(?=^[^\s#]|^  [A-Za-z_][A-Za-z0-9_-]*:|\z)')
    $settings = [regex]::Replace($trigger.Groups["settings"].Value, '(?m)#.*$', '').Trim()
    if (-not $trigger.Success -or $settings -notin @("", "{}")) {
      throw "RED: $($entry.Key) must report required checks for every PR, including documentation-only changes"
    }
  }
} finally {
  Remove-Item -LiteralPath $foreignJunction -Recurse -Force -ErrorAction SilentlyContinue
}

$oldWinghosttyRoot = [Environment]::GetEnvironmentVariable(
  "GRAPHCODE_WINGHOSTTY_ROOT"
)
$oldZmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
try {
  $env:GRAPHCODE_WINGHOSTTY_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-winghostty-provider"
  $env:GRAPHCODE_ZMX_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-zmx-provider"
  & $pwsh -NoProfile -File $runner -Task terminal-gate *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "terminal-gate passed without its pinned providers"
  }
} finally {
  if ($null -eq $oldWinghosttyRoot) {
    Remove-Item Env:GRAPHCODE_WINGHOSTTY_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_WINGHOSTTY_ROOT = $oldWinghosttyRoot
  }
  if ($null -eq $oldZmxRoot) {
    Remove-Item Env:GRAPHCODE_ZMX_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_ZMX_ROOT = $oldZmxRoot
  }
}

Write-Host "ValidationRunner.Tests.ps1: PASS"
exit 0
