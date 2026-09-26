# AGENTS.md

Guidance for coding agents working in this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first; everything there — licensing, the
[DCO](DCO) sign-off, and the pull request checklist — applies here too.

GraphCode is a macOS app (`graphcode/`) and a Windows port (`graphcode-windows/`)
over shared Swift (`GraphcodeKit/`). Most agent work happens on the Windows port,
which has its own pinned toolchain and the hard rules below.

## Bootstrap before anything else

**Do not hand-roll a toolchain environment, and do not install toolchains by
hand.** The repository already pins and resolves everything:

```powershell
pwsh -NoProfile -File Tools\windows\bootstrap.ps1
```

It installs the pinned Swift, downloads both pinned Zig versions, clones and
builds the pinned providers, and writes `.graphcode-tools\environment.ps1`.
Load that script in each new shell:

```powershell
. .\.graphcode-tools\environment.ps1
```

It exports the variables the build and test scripts expect:

| Variable | Purpose |
| --- | --- |
| `GRAPHCODE_SWIFT633` | Full path to the pinned `swift.exe` |
| `GRAPHCODE_ZIG0152` | Zig 0.15.2, for the Windows shell |
| `GRAPHCODE_ZIG0160` | Zig 0.16.0, required only by `zmx` |
| `GRAPHCODE_WINGHOSTTY_ROOT` | Pinned Winghostty provider root |
| `GRAPHCODE_ZMX_ROOT` | Pinned zmx provider root |

Pass `-SkipSwift` when you only need Zig and the providers; `-ToolRoot` and
`-ProviderRoot` relocate the tool and provider directories if the defaults
(`.graphcode-tools` and `.graphcode-tools\providers`) do not suit your session.

## Pinned versions

These are the single source of truth. Never silently upgrade one.

| Tool | Version | Pinned in |
| --- | --- | --- |
| Swift | 6.3.3 | `.github/workflows/windows-*.yml` (`swift-version: swift-6.3.3-release`), `Tools/windows/bootstrap.ps1` |
| Zig (shell) | 0.15.2 | `mise.toml`, `graphcode-windows/build.zig.zon` (`minimum_zig_version`) |
| Zig (zmx only) | 0.16.0 | `graphcode-windows/provider-pins.json` |
| Winghostty | `f5abc059e4ca58b376eb209313aca7784659c679` | `graphcode-windows/provider-pins.json` |
| zmx | `11e20c738b4ebd88031c7a01f1a9d938ee123234` | `graphcode-windows/provider-pins.json` |

If a build fails because a tool is missing or the wrong version, rerun
bootstrap. Do not fall back to whatever is on `PATH`.

## The Swift toolchain trap

`swift` on `PATH` is usually **not** the pinned toolchain, and a mismatched
toolchain fails against the `swift-tools-version: 6.0` manifest. Always use
`$env:GRAPHCODE_SWIFT633`, or the pinned toolchain's `bin` directory, rather
than a bare `swift`.

Two failure modes cost real time, so recognize them:

- **`swift --version` exits with `0xC0000139`
  (`STATUS_ENTRYPOINT_NOT_FOUND`).** The toolchain `usr\bin` is on `PATH` but
  the matching `Runtimes\<version>\usr\bin` is not. Add both, and prefer
  invoking `swift-build.exe` / `swift-test.exe` directly over the `swift`
  driver.
- **A development / "unknown-Asserts" toolchain under
  `C:\Library\Developer\Toolchains` wins on `PATH`.** It is not the pinned
  toolchain. Ignore it.

A working SwiftPM environment needs `SDKROOT` pointing at the pinned
`Platforms\<version>\Windows.platform\Developer\SDKs\Windows.sdk`, plus MSVC
`INCLUDE`/`LIB` for the installed Visual Studio and Windows SDK. Set these
**process-only**; never mutate machine or user environment variables.

## Dependencies are pinned and offline

`Package.resolved` pins `swift-collections` 1.6.0 and
`swift-identified-collections` 1.1.1. Build with
`--disable-automatic-resolution`. Note that flag alone can still fetch missing
checkouts, so also set `protocol.allow=never` process-only when you intend a
strictly offline build.

If a checkout is genuinely missing, reuse an existing local one at the exact
revision in `Package.resolved` and verify with `git rev-parse` before building.
Never resolve a different version, and never edit `Package.resolved` to make a
build pass.

## Building and testing

Use your own scratch, cache, config, security, and module-cache directories, and
redirect `TEMP`/`TMP`. Never write into another worktree's or session's build
directory; treat other sessions' artifacts as strictly read-only.

```powershell
# Windows shell (Zig) — run from graphcode-windows
& $env:GRAPHCODE_ZIG0152 test src\<File>.zig --test-filter "<filter>"
& $env:GRAPHCODE_ZIG0152 build -Doptimize=ReleaseSafe -Dwinghostty-dir=$env:GRAPHCODE_WINGHOSTTY_ROOT

# Repository validation
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task windows-shell -SkipTrayLive
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task packaging
```

Zig test roots that import native headers need explicit target and link flags,
for example:

```
-target x86_64-windows-msvc -lc -luser32 -lgdi32 -ladvapi32 -I<winghostty>\include
```

A `--test-filter` that matches **zero** tests still exits successfully. Always
assert a positive executed test count; a filter typo is not a pass.

New Zig test roots must be registered in `Tools/windows/Tests/WindowsShell.Tests.ps1`,
which derives coverage from literal `& $zig test src\<File>.zig` invocations.

## Evidence and claims

This port is validated incrementally, and overstated evidence has repeatedly
caused rework. Be exact about what you actually ran.

- Follow the repository's test-first practice: write the test, observe it fail
  for the intended reason, then implement. Preserve the failing output.
- Distinguish a **compile** failure (a missing API) from a **behavioral**
  failure. A compile error is not proof of runtime behavior.
- Preserve failure evidence. Never overwrite a failing log with a passing one,
  and never fold a corrected mistake silently into a success summary.
- A green build, a filtered test run, or a green CI workflow does **not**
  establish native keyboard input, UI Automation/TextPattern conformance, real
  glyph rendering, daemon persistence, macOS parity, or hardware behavior unless
  that exact path ran. Keep such claims marked Partial in
  [investigation/ui-parity-matrix.md](investigation/ui-parity-matrix.md).
- A manually dispatched workflow run is not the same as a pull request's
  required checks.

## Pull requests

- Sign off every commit (`git commit -s`); the DCO check is required. Keep
  commit messages UTF-8 with LF endings.
- Keep changes scoped to the files your task owns. Several agents work in
  parallel across this repo, and overlapping edits to shared surfaces such as
  `App.zig`, `GraphModel.zig`, `NativeForms.zig`, and `GraphStore.swift` need
  explicit coordination.
- Fill in the pull request template, including the test plan, and state its
  limits honestly.
- Never force-push a branch another session owns, and never bypass required
  checks.
