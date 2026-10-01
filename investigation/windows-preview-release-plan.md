# GraphCode Windows preview-readiness plan

## Release verdict

**An invitation-only tester preview need not wait for full macOS parity, but a
useful agent-terminal alpha is not yet qualified.** The distribution machinery
exists now; building a ZIP is a different milestone from proving that someone
can install it, work with an actual agent, and safely resume their project.
The critical path is terminal correctness plus a packaged production-daemon
flight, followed by fixes for any reproduced core bugs. It is not closing all
35 Partial rows, and it is not just visual polish.

Assessment date: **2026-10-01**. Accepted source floor:
`0765419a6d1e7ad401422903edf9102dbf0c9a17`, including the landed
[refresh/navigation fix #549](https://github.com/scgopi/GraphCode/pull/549).
At that floor, the [parity ledger](ui-parity-matrix.md) contains **98 surfaces:
63 Validated and 35 Partial**. This plan changes no parity status or evidence.
A newer candidate must be qualified at its own exact source and package hashes.

The live release API was checked on this date:
[v0.1.77](https://github.com/scgopi/GraphCode/releases/tag/v0.1.77), published
2026-09-29, is the latest stable release and contains only
`graphcode-macos-arm64.dmg`, not a Windows ZIP. No package was built, installed,
or published for this documentation assessment.

**Engineering distance:** if the proposed profile passes the production flight,
the remaining release work is bounded qualification and tester handoff, not a
parity programme. If an actual agent's output is unreadable, input is lost,
resize corrupts output, or persistence fails, real implementation work remains
before even this narrow preview. Those paths are not sufficiently witnessed to
give a credible calendar estimate. A successful package build or one harness
pass cannot settle that uncertainty.

## Delivery lanes

Delivery priority and macOS equivalence are independent. The lanes below overlay
the ledger; they do not replace its definition of `Validated`.

| Lane | Meaning | Preview rule |
|---|---|---|
| **F - FUNCTIONAL BUGS / core qualification** | Broken or insufficiently qualified behavior needed for the advertised local workflow; includes input/output correctness, navigation, persistence, legibility, liveness and data safety | Fix reproduced product bugs and witness the core path before inviting testers. Missing evidence is not itself proof of a bug. |
| **O - OPTIONAL FUNCTIONALITY** | Real features outside the narrow preview, not cosmetic work: remote projects, richer topology, custody/promotion, worktree automation and self-update | Defer explicitly. If an exposed action could corrupt data or leave the app unusable, qualify or guard it; a disclaimer is not a safety mechanism. |
| **P - POLISH** | Appearance and discoverability improvements after controls and text are already usable: exact palette/materials, shape smoothing, ClearType refinement and extra hints | Continue after preview. Unreadable text, indistinguishable state or unreachable controls move to F. |
| **E - EVIDENCE GAPS** | The required observation has not run or is not reliable: production versus stub, native input versus helper, real pixels versus metadata, client hardware versus hosted server | Obtain the specific evidence. A core-path gap holds qualification; an optional/parity-only gap can remain open. Never convert NotExecuted or an empty result into PASS. |

Mixed rows are split within their notes. Clipboard, IME, DPI, accessibility and
font quality are not blanket polish categories. Existing code bugs blocking
either parity or ordinary app features are legitimate functional work.

## Proposed invitation-only scope

The first audience is technical **Windows x64** testers using their own or
disposable **local** projects and an already installed, authenticated agent CLI.
Propose Windows 11 x64 as the first client qualification profile; record the
actual OS build, display work area, scaling, graphics adapter, shell and agent
CLI version before advertising support. Qualify at least 100% and 150% scaling
and a declared minimum viewport. Other OS/display/input profiles are not
implicitly covered by server CI.

The useful minimum is: install without developer toolchains; open a local
folder; create, render and select loops; rename and edit basic fields; open a
readable, responsive terminal for **one named, actually tested backend** from
the supported Copilot/Claude/Codex choices; send input, observe output and stop
the intended loop; reopen the same saved project/session state. Do not advertise
all three backends merely because their selectors exist.

Manual verified-ZIP updates are acceptable. Full remote/SSH/Codespaces support,
multi-workspace automation, every graph topology, touchscreen/trackpad fidelity,
GPU-wide coverage, exact macOS visuals and self-update are not prerequisites
unless the chosen core workflow actually depends on them. Visible deferred
features must have honest capability/error behavior and safe boundaries.
This is an opt-in unsigned technical preview, not GA, a mature beta, or a claim
of accessibility or macOS parity.

This narrower milestone is distinct from the broader
[Windows implementation plan](windows-implementation-plan.md), whose release
gate includes remote and complete parity work. Its historical "complete"
acceptance statement is not current preview qualification. No broad release
policy or macOS policy is changed here.

## Current evidence and attribution limits

The ledger's validated onboarding/empty states, local ingress, settings,
sidebar identities, project canvas controls, Quick Chat entry points, workspace
chrome, explicit connection errors and tray lifecycle support the proposed core
flow. They are useful existing evidence, not 63 certifications of an installed
production-agent experience; many observations use deterministic fixtures.

- **Terminal:** the [Windows shell README](../graphcode-windows/README.md)
  describes a default legacy ASCII path/current 120x40 text grid and an opt-in
  `GRAPHCODE_EXPERIMENTAL_TERMINAL_VT` parser. The existing pinned VT library
  retains grapheme metadata, but the native host still uses narrow,
  single-codepoint 5x7 patterns. Unsupported opt-in host cells explicitly refuse
  publication and retain old pixels while accessible text may advance. That
  is an honest failure, not matching visible output. The ledger separately
  records pane-bound-derived backend surface sizing and a minimize/restore
  state fix; this does not resolve the README's fixed-grid account or prove
  actual PTY resize negotiation. Record visible grid, PTY dimensions and
  wrapping in the production flight rather than selecting the optimistic
  description. Scrollback/wheel/selection, native glyph/caret rendering and
  terminal UIA conformance remain incomplete or unqualified. An ASCII-only
  promise is not sufficient for a Copilot/Claude/Codex TUI without witnessing
  its actual output and required interaction.
- **Packaging:** [existing packaging machinery](../Tools/windows/PACKAGING.md)
  and reported CI lifecycle evidence cover real scheduled-task installation,
  locked upgrade, upgrade, rollback, uninstall and standalone Windows
  PowerShell 5.1/PowerShell 7 paths. Clean-environment tests are not a new
  physical clean-machine flight. These paths do not prove the installed UI,
  production `graphcoded` and an actual agent working together. Likewise, a
  successful packaging/release-gate step does not make a failed overall
  workflow green.
- **Refresh and input:** #549 is a landed product fix, even while whole parity
  rows remain unchanged. The separate
  [rename/refresh qualification #547](https://github.com/scgopi/GraphCode/pull/547)
  has no accepted new native GREEN at this snapshot. Its latest reported
  driver run passed blank validation but later read `lpha renamed` instead of
  `Alpha renamed`, then stalled during a subsequent clear/text step despite
  reported enqueue counts. The driver lacks a clear-completion fence and is
  being fixed separately. This is not an observed production Win32 cause for
  the lost leading character. Reproduce against the production path or use an
  authorized manual flight before classifying it as an app input bug. Even a
  reliable rename/stub pass would not qualify Edit Details or richer global
  topology.
- **Provider:** [coneilen/winghostty#10](https://github.com/coneilen/winghostty/pull/10)
  has a queued interactive check with no available runner at this snapshot.
  That is a provider evidence/availability gap, not proof that every current
  terminal is unusable. The hosted Windows Server x64/Mesa CPU real-GL route is
  actively implemented (candidate `cc0de7a9`), but not yet qualified. It must
  pass unchanged rendering/GUI assertions and its desktop capability canary;
  it would still not prove Windows 11 client/hardware behavior. No runner
  provisioning or successful qualification is assumed. No GraphCode repin
  follows without separate validation and approval.
- **Modal and visual evidence:** bounded historical 96-DPI production drawing
  captures exist. There are zero accepted matched current Windows/macOS
  reference pairs, not zero Windows captures of any kind. The separate modal
  diagnostics exhausted four native trials without accepted input/cancel/
  teardown proof; a 75-case matrix with 70 NotExecuted entries is not a pass.
  Unclassified processes blocking diagnostic-artifact retirement do not
  establish an app leak. Those gaps remain distinct from reproduced app bugs
  and from accepted private geometry/capture-mock results.
- **Updater:** implementation and helper coverage exist despite older README
  wording saying installation is not implemented. The absent published Windows
  asset still prevents the real enabled-offer/download/install/relaunch flight.
  Publishing an asset alone will not prove upgrading the running EXE or
  preserving sessions through that upgrade.

The accepted provider inputs remain Winghostty
`6286560d0aa3103e068b2b7afa81eac373d870c9` and zmx
`785b3fd15dcafd1882b495c831a10f98c201b908`, with shell Zig 0.15.2,
zmx Zig 0.16.0 and Swift 6.3.3. This plan proposes no pin or toolchain changes.

## Partial-surface delivery map

All **35** current Partial surface names appear once below, in ledger order.
An alpha disposition is conditional on the gates, not a promotion to parity.
F means core usability/safety qualification; O means optional functionality;
P means genuinely cosmetic/discovery refinement; E identifies the missing
observation. Notes distinguish the parts of mixed rows.

| Partial ledger surface | Delivery lane | Alpha disposition | Remaining behavior and evidence |
|---|---|---|---|
| Main split view | F + P + E | Qualify core | Require stable local canvas/workspace/sidebar transitions, including welcome and narrow viewport, without focus theft. Existing live destination evidence supports this; populated production content and small-display usability still need a flight. Exact visual layout matching can follow. |
| Window toolbar | F + O + P + E | Qualify core; defer extras | Reachable Jump and workspace/detail navigation must not overlap or lose focus at the declared viewport/DPI. Populated Needs You and threshold-driven worktree content lack a complete comparison; defer unneeded worktree aggregation and exact chrome, not unreachable core actions. |
| File/Loop/Terminal menus | F + P + E | Qualify core | Witness core commands and state-aware enablement in graph and terminal contexts with actual keyboard/menu use. Live subsets and hidden HMENU tests are not the complete route. Extra shortcut hints and macOS ordering fidelity can wait after commands work. |
| Workspace lifecycle | F + O + E | Qualify safety; defer multi-instance features | Default/local reopen must preserve state. New/Rename/Delete and running-instance paging have helper coverage but no complete shown native lifecycle; delete's recycle/daemon/session effects are injected. Qualify exposed destructive behavior in disposable fixtures or guard it before preview; defer live totals and multi-instance automation, not safety. |
| Loop row presentation | F + P + E | Qualify identity; defer refinement | Require readable correct title/state/identity in the agent flow. Elapsed formatting has unit coverage but no rendered-column observation; exact time-column spacing and pixel parity can wait. Incorrect or misleading live state is functional, not decoration. |
| Cross-project global graph | F + O + E | Qualify navigation; defer richer topology | Local lane selection must retain the intended project during foreign refreshes; #549 fixes a real reset bug at this floor. Two-project production navigation still needs a flight. Defer richer topology/START furniture, filtering and remote/all-project worktree binding; one harness success does not close those residuals. |
| Notebook grid | P + E | Defer | Grid geometry follows pan/zoom in helper tests, but live line spacing has not been pixel-asserted. Finish direct rendered grid evidence and macOS styling later unless the grid makes content unreadable or impedes hit testing. |
| Pan and anchored zoom | F + O + E | Qualify mouse; defer hardware expansion | Verify mouse pan/wheel/visible zoom controls keep local cards reachable and selection accurate. Touchscreen routing is source/unit-covered, not hardware-witnessed; Precision Touchpad pinch is separate. Defer those additional device profiles rather than claiming support. |
| Loop card identity | F + P + E | Qualify meaning; defer exact styling | Live type/title/state/entry meaning must be readable and match the actual node. Focused stripe tests are not rendered evidence for this row. Exact stripe colors and macOS shape matching are polish only after state distinctions remain clear. |
| Edge presentation | F + P + E | Qualify exposed meaning; defer exact styling | For exposed connections, labels/endpoints/fired state must not misrepresent configuration or obscure actions. Exact strings/static bounds are covered; visible wording and rendered state still need review. Full style, collision placement and macOS summary fidelity can follow. |
| Edge creation sheet | F + O + E | Qualify exposed form; defer advanced graph scope | Real native input/validation/dispatch ran with a protocol stub; real-daemon persistence was separately headless. Qualify cancellation, exact endpoint/configuration preservation and visible result on the packaged path if offered. Defer advanced transforms/cycles outside the profile only with safe refusal; no combined production-UI persistence proof yet. |
| Custody child creation | O + F + E | Defer feature; guard exposed path | Owned-target queue tests cover unresolved parents and inherited backend, not native selection or production acceptance/persistence. Defer custody/report-back workflows. If reachable, cancellation/stale-scope/attachment handling must remain safe; template-backend and downstream-send failure residuals are functional, not polish. |
| Edge editing | F + O + E | Qualify exposed editing; defer deeper scope | Stub-backed native edit/cancel and separate headless production persistence exist. Require exact unchanged ID/endpoints/runtime count, one intended change and no cancellation mutation on the package if exposed. Deeper wrappers remain refused; edge UIA and macOS-equivalent edit surface are absent, not cosmetic gaps. |
| Node creation sheet | F + O + P + E | Qualify basic creation; defer advanced choices | Native type/validation/result evidence uses a stub, while production persistence is separately headless. Qualify typed exact input, scrolling, cancel and retained project context with the real package. The recorded stale tile recap defect was fixed by [#543](https://github.com/scgopi/GraphCode/pull/543); lost UIA census still needs attribution. Nondefault inspected branches, attachments/picker/paste/drop and templates can be deferred with safe boundaries; teaching-tile styling can follow. |
| Node update/rename | F + O + E | Qualify rename and basic edits | Require exact title propagation to graph/sidebar with stable ID, open/cancel/submit Edit Details, clear-versus-unchanged semantics and reload persistence. #549 and pending #547 do not substitute for that combined flight. Diagnose driver clear/focus sequencing separately from product input; defer nonessential typed retypes, not required basic edits. |
| Canvas context menu | F + O + P + E | Qualify core actions and safety | Live menus and one edge edit/cancel were observed, not every invoked outcome. Open/Rename/Edit/Stop and named destructive cancellation need the packaged flight. Defer child/import/export/promotion flows safely; exact menu presentation is polish only after reachable commands target the right object. |
| Sketch promotion | O + F + E | Defer feature; guard exposed path | Queue/helper and headless daemon acceptance exist; [#542](https://github.com/scgopi/GraphCode/pull/542) observed hosted stub-backed native Goal/Turn/Timed promotions. Active real-backend/session continuity remains unqualified, so the row stays Partial. Defer conversion outside the preview scope; if exposed, verify or guard identity/session/history preservation and cancellation. Synthetic session markers do not establish real continuity. |
| Terminal VT state and rendering | F + O + P + E | Core release gate | Witness actual agent output, Unicode/graphemes it emits, wrapping, resize negotiation, cursor/input and liveness with visible pixels matching current state; unsupported-cell rejection/old pixels is not success. Parser memory tests and surface-size helpers cannot prove this. Extended scrollback/selection features may defer only if the CLI remains usable; font smoothing is polish only after readable correct rendering. |
| Mounted background tabs | F + O + E | Qualify exposed continuity | Corrected selectors exclude close buttons, but no new complete live tab/backend round trip is proven. If tabs/splits are offered, switch back to the same session/output/focus without unintended close or input delivery. Defer extra topology automation, not continuity of an exposed control. |
| Show in Graph | F + P + E | Qualify round trip | Focused live evidence supports action/identity return, not a new complete gate or native Loop-menu route. Verify the production terminal-to-card-to-same-loop transition and focus. Extra hints are polish; wrong destination or stale provider binding is functional. |
| Add Codespace sheet | O + E | Defer | Only real 403/remediation ran; successful discovery, selection, validated dial and sheet walkthrough remain absent. Keep Codespaces outside this local preview with explicit capability/error handling; do not require new credentials/scopes to qualify the local app. |
| Worktree notice chip | O + F + P + E | Defer automation; qualify honest status | Count/size/ownership helpers are covered, not automatic discovery, global titlebar aggregation or authentic multi-lane review. Defer that functionality and chip fidelity. Stale/unknown counts must remain honestly unavailable, and any exposed review/reclaim action must retain its safety guard. |
| Available update alert | O + F + E | Defer self-update; qualify honest offer | The real feed currently supplies no Windows ZIP, so Install is disabled with a reason. Enabled installation has not run end to end. Manual verified ZIP updates suffice; do not offer a non-Windows or unverified payload as an installable update. |
| Install progress | O + F + P + E | Defer self-update | Real HTTPS progress/checksum refusal does not prove real Windows extraction/upgrade, especially with the running EXE locked. Keep automatic install outside preview until that flight passes; verify manual upgrade/rollback instead. Progress styling can wait, but integrity and recoverable failure cannot. |
| Relaunch prompt | O + F + E | Defer self-update | Unit outcome/copy does not prove real installed relaunch or zmx continuity through self-upgrade. Require manual-update reopen continuity for alpha; defer Now/Later automation until a real Windows asset and running-process upgrade flight establish the claimed behavior. |
| Install failure | O + F + P + E | Defer self-update; qualify safe recovery | Value-owned error mapping and injected browser invocation are covered, not an actual failing install/browser handoff. Manual installation must report cause and recovery paths without false success or lost data. Automated failure UX and exact presentation can follow with the updater. |
| UI Automation tree | F + O + P + E | Qualify core reachability; defer full conformance | Stable live shell identities do not prove every dialog or terminal Text/Text2 range/selection/caret. Qualify named core controls, focus and keyboard reachability for the declared profile; treat production repros of inaccessible required actions as functional. Full provider/range conformance and extra HelpText remain separate work, not a blanket cosmetic waiver. |
| Keyboard discovery | F + P + E | Qualify reachable commands; defer extra hints | Current menu/Help labels cover mapped core shortcuts, but canvas gestures and sidebar reorder lack visible hints. Verify usable mouse/keyboard routes for core tasks and exact text entry; then defer supplementary gesture guidance. A missing effective route is functional, not just a hint gap. |
| IME/dead keys/layouts | F + O + P + E | Qualify declared input profile | Committed Japanese callback and hidden native dead-key/layout tests do not prove foreground terminal composition. No lost/duplicated committed text in supported form/terminal input is allowed; explicitly qualify supported layouts and non-ASCII scope. Defer additional language profiles and preedit presentation only where basic input remains usable, not required committed text. |
| Clipboard/selection | F + O + P + E | Qualify relied-on paste; defer richer selection | Conversion/classification tests did not access the real clipboard or witness terminal selection. Verify exact safe single-line paste and no unsafe multiline/control execution if paste is offered or needed; visible refusal must be usable. Mouse selection/copy/offset correctness requires a leased desktop fixture; richer selection and hints can defer, silent input/data loss cannot. |
| Per-monitor DPI | F + O + P + E | Qualify supported scales; defer wider monitor matrix | Startup awareness/font-scale propagation and metrics tests are not a real multi-monitor flight. At declared scales and viewport, all required controls/text must remain reachable/readable with correct hit bounds. Defer unadvertised monitor combinations and exact sizing fidelity, not clipped essential controls or wrong input coordinates. |
| Dark visual language | F + P + E | Qualify legibility; defer full styling | Historical 96-DPI captures cover bounded canvas/settings/workspace samples, not all sheets/states. Review core contrast, state hierarchy and readable error/disabled text on the candidate. Exact dark materials and macOS matching can wait; illegible status or indistinguishable actions are functional failures. |
| Font rendering quality | F + P + E | Qualify readability; defer exact smoothing | Segoe UI/ClearType requests and color-count samples do not certify every face or legibility, especially terminal glyphs. Qualify readable native controls and actual agent output at declared DPI first. ClearType/anti-alias refinement and matched macOS typography then become polish. |
| Line/shape anti-aliasing | P + E | Defer | Bounded real GDI+ captures show selected-card/sparkline samples, not all edge styles/DPI states or macOS equality. Improve dashed/grid/preview smoothing and collect matched evidence after the relevant lines/actions are already distinguishable and usable. |
| Color palette fidelity | P + E | Defer | A bounded COLORREF channel bug was corrected with real before/after samples and static token mapping; that is meaningful progress, not every tone/material/state matched to macOS. Defer exact gradients and full matched captures while preserving core contrast and redundant state meaning. |

## Alpha release gates

These are acceptance conditions for a future authorized flight, **not results
of this documentation change**. Keep a versioned record with positive executed
counts, expected/actual values, failures and retained evidence. Required native
input, clipboard, display and destructive tests need an owned Windows desktop
lease or equivalent authorized hosted evidence. No desktop available means a
proof gap, not PASS; hosted server evidence must not be relabelled client proof.

- [ ] **Exact artifact:** record candidate source SHA, version, peeled tag SHA,
  package SHA-256, manifest and provider provenance. Tag/source must match.
  Verify the actual ZIP and extracted standalone setup with the existing
  package verifier; confirm the declared unsigned state and bundled production
  daemon/CLI/runtime inputs, not substitutes.
- [ ] **Clean installation and recovery:** install the extracted candidate on
  the declared client profile without Git/Swift/Zig/SDK developer dependencies.
  Observe the installed scheduled daemon endpoint and normal app launch.
  Perform a real manual upgrade, locked-upgrade refusal/rollback and uninstall;
  compare fixture user-data bytes before/after. Uninstall preserves data by
  default, and failure reports actual recovery paths. Existing CI supports,
  but does not replace, this chosen-package check.
- [ ] **Production core flow:** with production `graphcoded`, not the protocol
  stub or gate-seeded model, open an owned fixture project; create exactly one
  intended loop, render/select it, rename and edit basic fields, then reopen
  and read the persisted state. Use exact typed sentinels such as
  `AlphaRenamed` and `A-start-Z-end`; graph/sidebar/model must agree on title
  and stable ID. A changed editor cancellation must leave configuration
  unchanged. A driver failure requires attribution or an independently
  qualified manual flight, not an inferred product cause.
- [ ] **Useful agent terminal:** run one named supported agent CLI/version in
  that project. Observe real readable prompts/output, type and receive exact
  expected input/output markers, interact with its required controls and stop
  the intended loop without freezing the app or losing unrelated output.
  Exercise resize, wrap, minimize/restore and any offered tab switch; verify
  visible state against actual PTY dimensions/output. Include non-ASCII text
  in the declared scope and the glyphs/graphemes the CLI itself emits. Old
  pixels after unsupported-cell rejection, a parser snapshot, or queued input
  counts cannot satisfy this gate.
- [ ] **Reachability and lifecycle:** at the declared minimum viewport and
  supported 100%/150% profiles, actually reach every required form control,
  validation/error, menu and terminal action with native input. Confirm exact
  supported non-ASCII/dead-key entry and any relied-on clipboard paste without
  loss or unintended execution. Exercise close-to-tray, explicit app Exit,
  daemon interruption/recovery and reopen; record which processes/sessions
  should persist or stop, and verify those boundaries and saved state.
  No crash, freeze, focus trap, unexplained output loss or silent error passes.
- [ ] **Safe mutations:** in disposable fixtures, exercise named cancel and
  confirmed delete/remove flows, including reachable workspace destructive
  operations. Cancellation must leave files/configuration/session identities
  unchanged; confirmation must affect only its captured target and report
  partial failure accurately. Any unqualified unsafe exposed operation must
  be fixed or guarded before preview, not waived by "use at your own risk."
- [ ] **Honest tester handoff:** provide supported OS/display/backend versions,
  known limitations, unsigned/SmartScreen and organization-policy warnings,
  verified download/checksum instructions, install/manual-update/uninstall
  steps, recovery locations and a bug-report route. Never ask testers to bypass
  security policy. Invite only after the core gates have actual evidence.

## Publication and tester handoff

Use the existing [release workflow](../.github/workflows/windows-release.yml)
and [release script](../Tools/windows/release.ps1); no new installer, signing
programme or automated release policy is needed for this preview. The workflow
is manual-dispatch only, checks out an **existing tag**, and defaults
`publish` to `false`. The script builds/verifies the ordinary **UNSIGNED** ZIP
and produces `graphcode-windows-x86_64.zip` plus its `.sha256` sidecar.
Checksums detect corruption; they do not authenticate the publisher.

After qualification, the maintainer chooses an authorized preview version/tag
for the **qualified source**, builds with publication disabled, verifies that
artifact and its provenance, and separately approves publication. Do not reuse
the older v0.1.77 tag for unrelated newer HEAD, overwrite its assets, or change
macOS release policy. `release.ps1` refuses a tag/source mismatch before
publication, and forbids `-AllowTagMismatch` with `-Publish`. Its upload
overwrite capability is not authorization to replace a released artifact.
Give testers the explicit preview release URL, not an assumption that a
prerelease is served by the stable `latest` route.

The tester packet should name one supported initial workflow, the exact
artifact/checksum, safe local-fixture setup, the actual demonstrated support
profile and the deferred features above. Manual updates use the new extracted
`GraphCode-Setup.ps1` and its existing verification/upgrade/recovery path.
Do not enable or advertise in-app install/relaunch until its own real
running-EXE/session-continuity flight passes. This plan neither creates a tag
or release nor dispatches CI, uploads assets, installs an app or changes pins.

## Measuring progress

Track two independent outcomes: **whole-row parity closures** under the ledger's
unchanged macOS-equivalence/runtime rule, and **observable product bugs fixed or
core release behaviors newly qualified** with exact source/evidence. The
unchanged 63/35 split across the last eight ledger commits (September 28-30)
does not mean no progress: narrowed evidence, cancellation/persistence work and
the landed refresh-navigation fix matter even when a row has other residuals.
Conversely, PR counts, unit-test totals and harness enqueue counts are not
user-visible completion.

For each core gate, record NotExecuted/Failed/Passed on the chosen package,
the reproduced product issue (if any), and the next specific missing
observation. Keep optional-feature and polish backlog progress separate.
Release the scoped preview when the core/safety gates pass; continue parity
and polish afterward without renaming, splitting or promoting ledger rows to
make the release appear closer.
