# macOS parity evidence: current Partial rows

**Scope:** Read-only inspection of the original repository's 35 `Partial` rows in
`investigation/ui-parity-matrix.md` at
[`717240cdb373a2c00644842c429f06e520d15f51`](https://github.com/scgopi/GraphCode/commit/717240cdb373a2c00644842c429f06e520d15f51)
in https://github.com/scgopi/GraphCode. Ledger statuses were not changed. The
ledger's `Install failure` description still describes an earlier Windows
browser handoff while its neighboring rows describe a newer installer; treat
the current Windows implementation as requiring its own verification, not as
macOS evidence.

**Environment / provenance:** Investigation 2026-09-28, 12:02-13:37 PDT
(UTC-07:00); macOS 26.7 (25G229), Apple Silicon. Main ASUS display 3840x2160
physical / 1920x1080 logical (2x); secondary Dell 1920x1080 physical /
1920x1080 logical (1x). The isolated **running** build's `Info.plist` confirms
**GraphCode 0.1.76, build 299**, bundle
`local.graphcode.parityfb7e49d1.app`; it was built from the exact inspected
SHA in a separate disposable checkout. The pre-existing, older
0.1.73-beta3/288 DerivedData binary was **not** run. Initial window 900x524
logical points on 2x; comparison window 1400x820 points on both 2x and 1x.
PNG pixel dimensions include macOS capture margins, shadows and sheets; see
the artifact index. Colors can differ by display profile/material. No capture
was retouched or annotated.

**Setup and fixture:** With explicit authorization for a separate checkout
and temporary foreground daemon, cloned this SHA, initialized the pinned
Ghostty/zmx submodules and Tuist dependencies, and built both with pinned Zig
0.15.2 using Xcode 16.4's macOS 15.5 SDK through the repository SDK shim.
Generated an isolated bundle ID and built app/daemon into disposable
DerivedData. The debug app contains no packaged helper directory, and no
LaunchAgent was installed. The app and daemon shared only an isolated support
directory and an ephemeral short Unix socket. Created **Alpha** and **Beta**
as disposable local Git repositories with an empty signed commit each;
Alpha had 2, then 8, then 7 linked worktrees, besides its primary checkout.
Created one *unpiloted* Composite in each project; inside Alpha created an
inert Goal and Main child and a Handoff edge. No account, Codespace, release
asset or coding provider was provisioned or run. The only live observations
are those explicitly identified below. Screen Recording and Accessibility
permissions were enabled for the capture/automation host.

**Evidence key:** `S` = inspected source; `T` = test-source reference (only the
ten named suites below were **executed**); `R` = direct observation of this
**running** app. The selected
`GraphOverviewTests`, `WorktreeHygieneTests`, `NotebookGridTests`,
`CanvasTransformTests`, `CreatedByLoopTests`, `SketchPromotionTests`,
`LoopRenameTests`, `MountFocusPolicyTests`, `GhosttyAppearanceTests` and
`UpdateInstallTests` were executed once with `xcodebuild test` against the
isolated checkout: `xcresulttool` reported **113 passed, 0 failed, 0 skipped**
across ten Swift Testing suites. The XCTest adapter also emitted “Executed 0
tests”; that line is **not** the result of the Swift Testing suites. This is
focused automated evidence, **not** a full `make test`, running-update,
native-terminal or Windows test. `make doctor` initially found this worktree's
missing prerequisites; those were supplied in the disposable checkout only.

Repository-relative source prefixes in the findings table:
`A/` = `graphcode/Sources/Features/App/`;
`O/` = `graphcode/Sources/Features/Overview/`;
`P/` = `graphcode/Sources/Features/Project/`;
`C/` = `graphcode/Sources/Features/Canvas/`;
`L/` = `graphcode/Sources/Features/LoopWorkspace/`;
`W/` = `graphcode/Sources/Features/Worktrees/`;
`G/` = `graphcode/Sources/Infrastructure/Ghostty/`;
`K/` = `GraphcodeKit/Sources/Domain/`;
`T/` = `graphcode/Tests/`. Each reference names a file and a symbol/section;
line numbers identify the inspected commit, not a future branch.

## Row-by-row findings

The **Runtime** column distinguishes observed parts from unverified states.
`none (fixture)` in **Artifact** means the needed provider, authenticated
service, release asset, or hardware/input fixture was deliberately not used,
**not** that behavior was absent. Capture filenames below are relative to
`evidence/`; exact pixels/scaling and scenarios are indexed later. Confidence
rates the stated *bounded* finding, never blanket platform equivalence.

| Current Partial row | macOS behavior (S; R where indicated) | Source / test-source references | Runtime | Artifact | Specific Windows parity implication | Confidence |
|---|---|---|---|---|---|---|
| Main split view | `NavigationSplitView` keeps the sidebar while detail routes among welcome, global/project graph, Quick Chats and workspace. | `A/AppView.swift:AppView.body` 24-42,85-177; `T/AppFeatureTests.swift`, `T/OnboardingViewTests.swift` (S/T). | **Observed** 900x524 welcome, empty global/Quick Chats/Alpha, then 1400x820 nested Alpha and two-project overview with same sidebar. Terminal detail not reached. | `empty-welcome-original.png`, `empty-quick-chats-original.png`, `alpha-empty-project-original.png`, `two-populated-project-lanes-original.png` | Preserve distinct destinations with persistent sidebar; terminal and narrow-width routing still need runtime proof. | High for observed destinations |
| Window toolbar | Named workspace title, conditional Needs You/worktree notice, always-visible Jump and context-only loop panel toggle on native material. | `A/AppView.swift:toolbar` 89-169; `A/TitlebarItems.swift`, `A/ProjectHeader.swift` (S). | **Observed** `GraphCode — runtime`, Jump and an amber **Alpha · 8 reclaimable** toolbar control at 8 linked worktrees; no notice at 7 after refresh. Needs You and loop rail not exercised. | `eight-worktree-notice-original.png`, `seven-worktrees-no-notice-original.png` | Distinguish app-wide project-owned notices, visible Jump and contextual panel; do not assert unobserved controls. | High for count boundary, Low for other chips |
| File/Loop/Terminal menus | File groups Workspace and local Worktrees; Loop groups Jump, attention, navigation, Show in Graph, stop/restart/broadcast; Terminal groups tabs/panes. Key equivalents declared; `⌘W` pane, `⇧⌘W` window. | `A/GraphcodeCommands.swift:body` 19-166; `T/GraphViewLoopMenuTests.swift`, `T/SplitPaneFocusTests.swift` (S/T). | **Observed** native menu/enablement through AX: global Graph has File Worktrees disabled, Loop Jump/Next/Previous/Restart All enabled, Show in Graph and all Terminal actions disabled; menu labels listed in runtime notes. No actual key equivalent or Terminal-context invocation. | none (AX-only menu observation; menu bar outside window capture) | Keep menu groups/state-aware enablement and separate pane/window close; test keyboard in a real workspace. | High for observed menu state, Medium for untested shortcuts |
| Workspace lifecycle | Workspace submenu lists Default/runtime, cycles, creates and manages; source protects default/current/open identities on mutation and reserves updates for Default. | `A/AppFeature+Workspaces.swift:workspace actions` 17-74,138-162,306-371; `graphcode/Sources/Features/Workspaces/WorkspaceSwitcher.swift`, `WorkspaceDialogs.swift`; `T/WorkspaceTests.swift`, `T/WorkspaceDeleteFlowTests.swift` (S/T). | **Observed** File > Workspace submenu and Manage sheet listing Default “0 loops · not running” versus isolated runtime “2 loops · this window”; Done/Escape dismiss. No create/rename/delete/multi-instance test. | `manage-workspaces-original.png` | Preserve workspace status and fail-closed lifecycle; defer launch/restore/delete conclusions. | High for list, Medium for guards from tests |
| Loop row presentation | Sidebar rows show loop title, colored type stripe, elapsed value and state/attention dot; remote reconnect remains source-only. | `A/AppSidebarView+Rows.swift:loop rows` 117-150,283; `A/LoopStateAppearance.swift`; `T/LoopCardPresentationTests.swift`, `T/LoopStateAppearanceTests.swift` (S/T). | **Observed** Alpha/Beta Composite rows with purple stripe, 0s→minutes elapsed and gray/amber status dots as nested Handoff blocked Alpha; remote not tested. | `alpha-composite-empty-original.png`, `two-populated-project-lanes-original.png` | Render distinct type/elapsed/state identity; test remote/reconnect separately. | High (sample pixels) |
| Cross-project global graph | Reserved optional global lane precedes project lanes; per-lane rollups and worktrees remain project-owned. Empty global lane omitted. | `A/AppFeature.swift:global graph` 685-686; `O/GraphOverview.swift:lanes` 26-32,137-152,237-267; `O/GraphOverviewView.swift` 72-123; `T/GraphOverviewTests.swift`, `T/CompositeAndGlobalGraphTests.swift` (S/T). | **Observed** two simultaneously opened disposable project lanes, each with a Composite card/START topology, and Alpha's `1 blocked` rollup; global lane remained empty and absent. A pre-fit overview briefly rendered content offscreen until Fit (capture retained), not evidence of missing lanes. No cross-project handoff. | `two-populated-project-lanes-original.png`, `two-project-overview-original.png` (pre-fit) | Preserve independent lane ownership, START geometry and empty-global omission; do not claim a populated global trigger from this fixture. | High for local lanes |
| Notebook grid | Non-hit-testable 48-point grid shares canvas scale/offset; hides lines at ≤6-point spacing. | `P/NotebookGrid.swift:NotebookGrid` 13-63; `T/NotebookGridTests.swift` 15-63 (S/T). | **Observed** rules on project/global canvases at 100%, 80% and Fit 63%; offscreen grid tests ran. Pointer-pan coupling was not physically driven. | `empty-global-graph-original.png`, `alpha-handoff-fitted-original.png`, `two-populated-project-lanes-original.png` | Couple grid and cards; retain computed far-zoom cutoff; no physical-pan claim. | High for samples/tests |
| Pan and anchored zoom | Anchor-preserving transform; 0.6-3x user range, 1.25x step, Fit down to 0.25x, auto-fit floor 0.8x. | `C/CanvasTransform.swift:zoom,fit` 5-119; `P/NotebookGrid.swift:rules` 23-39; `T/CanvasTransformTests.swift` 14-165 (S/T). | **Observed** pressing visible Fit recentered otherwise offscreen overview lanes and changed readout 80%→36% (900x524); at 1400x820 Fit displayed 63%; nested two-card Fit retained both cards. No pointer/wheel/pinch gesture observed. | `two-project-overview-original.png` (pre-fit), `two-project-overview-fitted-original.png`, `alpha-handoff-fitted-original.png` | Preserve anchored transforms but separately test actual wheel/pinch/touch input and center; Fit is not proof of those gestures. | High for Fit/test math, Low for input |
| Loop card identity | ~250x96-point card combines type accent, title, state, detail and metadata, with entry/connector and unwired roles. | `C/LoopCardView.swift:body,ports` 27-171,270-303; `T/LoopCardPresentationTests.swift` (S/T). | **Observed** purple Composite stripe, green Goal and white Main stripes; IDLE→BLOCKED after Handoff, UNWIRED “Wire it up / Mark as entry” before edge and ENTRY/START afterward. No fired/cycle/timed states. | `alpha-nested-two-nodes-original.png`, `alpha-handoff-fitted-original.png`, `two-populated-project-lanes-original.png` | Keep type stripe separate from state pill/entry/unwired roles; compare additional states later. | High for sampled cards |
| Edge presentation | Directed curve: unfired Handoff dashed, fired Handoff solid, message dim dashed, spawn purple dotted, guarded amber with optional retry label and fired blue pip. | `P/CanvasEdgeViews.swift:EdgeLineView,summary` 6-27,55-70,100-155; `P/ProjectCanvasView.swift:focus/menu` 220-269,424-438; `T/EdgeFocusTests.swift` (S/T). | **Observed** real unfired dashed Handoff from Alpha Goal to Main; Main became BLOCKED. Attempted edge right-click hit folder background; edge summary/focus, fired/guarded and other kinds not observed. | `alpha-handoff-fitted-original.png` | Render kind/fired/guard separately; retain large edge hit target and verify actual edge context access on hardware. | High for Handoff, Low for other states |
| Edge creation sheet | Connector drag onto another card opens New Edge with endpoint names and Kind/Fires/Hands off; loop-back defaults off, max passes 3, optional stop command and plateau. | `P/ProjectCanvasForms.swift:pending edge` 17-62; `P/ProjectFeatureState.swift:edge defaults/resolved guard` 514-563; `P/EdgeSpecForm.swift:body` 6-101; `T/PendingEdgeTests.swift`, `T/CycleGuardTests.swift` (S/T). | **Observed** physical connector drag Goal→Main opened the correct named sheet; toggling loop-back exposed max 3 passes/stop/plateau; toggling off and Create produced Handoff/BLOCKED state on live daemon. The expanded cycle form visibly **clipped** left labels/segmented control at 1400x820; don't treat that screenshot as a design target. Other kinds, cancellation, save/reload and guard execution not exercised. | `alpha-new-edge-form-original.png`, `alpha-edge-cycle-controls-original.png`, `alpha-created-handoff-original.png` | Preserve contextual endpoints/conditional controls and actual daemon result; avoid reproducing observed form clipping. | High for drag/default create, Medium for cycle UI |
| Custody child creation | Unresolved parent menus expose **New Child Node…**; source sets inherited editable backend and `createdBy` with daemon-owned fired custody link. Connector click makes an ordinary child/handoff instead. | `P/ProjectCanvasCards.swift:contextMenu` 83-89; `P/ProjectFeature.swift:child actions` 402-410; `P/ProjectFeature+NodeForm.swift:openNodeForm,create` 34-52,117-123,177-184; `T/CreatedByLoopTests.swift` (S/T). | **Observed** New Child Node… available on unresolved Composite and Main context menus; **not invoked**. Backend inheritance/fired custody link are test/source, not live. | none (AX-only popup; creation not invoked) | Keep custody distinct from ordinary connector child; verify daemon acceptance with an isolated child later. | Medium for visible action, High for source rule |
| Edge editing | **No macOS edge-edit affordance in inspected source**: its context menu summarizes and immediately dispatches Delete Edge without confirmation; configuration sheet is creation-time. | `P/ProjectCanvasView.swift:edge context menu` 424-438; `P/EdgeSpecForm.swift:creation form` 6-101 (S). | **Not observed**: created an edge, but precise right-click attempts hit the background folder menu, so actual edge menu/invocation remains unverified; absence claim is source-scoped only. | none (edge menu); `alpha-handoff-fitted-original.png` shows the edge alone | Treat Windows editing as an explicit extension/scope decision; do not infer a live macOS edit workflow. | High for source, Low for edge-menu access |
| Node creation sheet | New Node has teaching tiles, templates, type-specific inputs, Agent/Model/Branch and recap. Composite requires a name and promises nothing runs until piloted; Goal needs a done description, Main may start empty. | `P/NodeDraftForm.swift:body,validation/actions` 23-78,89-151,200-260; `P/NodeDraftTypeFields.swift:CompositeDraftFields`; `T/NodeDraftTests.swift`, `T/EntryLoopCreationTests.swift` (S/T). | **Observed** Alpha initial Main sheet default Agent Claude Code, Model Standard, Branch This folder; actual local picker had This folder, main, branch-one, branch-two, New branch…; Composite Create & open remained disabled until Name, Goal remained disabled until done description; created inert Composites and two children, no provider process. Remote/global branch or actual worktree binding not tested. | `alpha-new-node-form-original.png`, `alpha-composite-form-original.png`, `alpha-goal-validation-original.png`, `alpha-nested-two-nodes-original.png` | Preserve validation and exact local branch choices, but do not infer remote/global from this local fixture. | High for observed forms and create |
| Node update/rename | Context Rename… opens a named central alert with prefilled title and session/edge/work explanation; Return submits. Typed retype is a separate conditional form. | `P/ProjectCanvasCards.swift:contextMenu` 100-126; `A/AppView.swift:rename alert` 207-228; `P/ProjectFeature.swift:rename,retype actions` 557-595; `P/SketchPromotionForm.swift` 19-27,39-117; `T/LoopRenameTests.swift` (S/T). | **Observed** root Composite alert prefilled “Parity Alpha group”; Return renamed it “Parity Alpha graph” and overview/sidebar reflected change. **Observed limitation:** the nested Main context showed Rename…, but selecting it did not open an alert; `ProjectFeature.swift:567-568` only looks in root `state.graph.nodes`. Typed retype not exercised. | `alpha-root-rename-prompt-original.png`, `nested-rename-no-dialog-original.png` (post-click) | Preserve stable-ID rename across nested scopes; **do not copy this macOS nested action/guard mismatch** as intended parity. | High for reproduced root/nested paths |
| Canvas context menu | Background/folder menu differs from node menu; nodes conditionally offer child, composite/promotion/retype, rename, template, stop, export/import and Delete Loop…; edge menu source offers summary/delete. | `P/ProjectCanvasCards.swift:contextMenu` 83-155; `P/ProjectCanvasView.swift:context menus` 265-271,435-438; `A/AppView.swift:delete confirmation` 163-180 (S). | **Observed** pointer-opened Composite menu: Open Terminal, New Child Node…, Open Group, Pilot Once…, Arm Schedule **disabled** (not piloted), Rename…, Save as Template…, Stop, Export/Import, Delete Loop…; Main menu showed Promote to… submenu; background right-click showed Worktrees… 7/Settings/Finder/Export/Import. Edge menu and destructive confirmation not driven. | none (AX menu text only; no menu in window-specific capture) | Target and gate menu actions by kind/state; distinguish confirmed node deletion from immediate edge deletion source. | High for sampled menus |
| Sketch promotion | Sketches expose Goal/Turn/Timed promotion with target-specific validation, preserving ID; goal/time may start only when promoted in an appropriate scope. | `P/SketchPromotionForm.swift:body,validation` 1-191; `P/ProjectCanvasView.swift:sheet` 135-143; `P/ProjectFeature.swift:openPromotionForm` 702-715; `T/SketchPromotionTests.swift` 17-217 (S/T). | **Observed** Main context advertised Goal/Turn/Timed submenu. Promotion not submitted or exercised; nested promotion is guarded by root-only `state.graph.nodes[id:]` lookup, so nested availability needs correction/verification before declaring that menu operational. | none (AX-only menu; no submitted promotion) | Preserve identity/target validation and handle nested graph addressing deliberately; don't treat visible submenu as execution proof. | Medium (submenu), High (source guard) |
| Terminal VT state and rendering | Ghostty owns PTY/rendering; GraphCode syncs physical backing size, not a separate raw VT parser. | `G/GhosttyTerminalNSView.swift:init,viewDidChangeBackingProperties,syncSurfaceSize` 5-16,158-214; `G/GhosttyRuntime.swift` (S). | **Not observed**: no provider-backed terminal launched, so glyph/VT/cursor/scrollback and resize remain unverified. | none (terminal/provider fixture) | Compare actual VT/Unicode sequences and resize in native engines before claiming parity. | Medium (source integration only) |
| Mounted background tabs | Terminal tabs stay mounted; only selected surface is visible/hit-testable and active focus can claim keyboard. | `L/LoopWorkspaceView.swift:mounted tabs` 174-186; `G/GhosttyTerminalNSView.swift:active/visibility` 250-268; `T/MountFocusPolicyTests.swift` 8-72 (S/T). | **Not observed**: no running provider/PTY to hide or switch, despite focused mount-policy tests passing. | none (terminal/provider fixture) | Verify a real process remains live and selection/focus survives switching tabs/panes. | High for source/test, no live process proof |
| Show in Graph | Loop-bar and Loop menu route to graph; menu gated without workspace. | `L/LoopWorkspaceView.swift:onShowInGraph` 165-171; `A/GraphcodeCommands.swift:Show in Graph` 88-94; `T/GraphViewLoopMenuTests.swift` (S). | **Observed only unavailable state**: Show in Graph disabled on global graph without a terminal workspace; invocation/selected-card navigation not exercised. | none (AX menu state; no terminal) | Keep both discoverable commands; verify active-loop selection and focus from actual terminal. | High for disabled state, Low for action |
| Add Codespace sheet | `gh` discovers Codespaces and form supports selection/path/empty/error/retry. | `graphcode/Sources/Features/Welcome/CodespaceFormView.swift:body` 5-130; `graphcode/Sources/Features/Welcome/WelcomeFeature.swift:codespace actions` 356-434,462-503; `T/CodespaceTests.swift` (S). | **Not observed**: no permitted authenticated Codespaces access was supplied, and no account was queried. | none (authorized service fixture) | Prove discovery-success/path/dial only with separately approved credentials/scopes; do not infer from a 403. | High (source), no live service |
| Worktree notice chip | App-wide titlebar ranks project-owned notices; per-folder band shows total/reclaimable. Canonical primary checkout excluded by path; all other assessed entries count, nonprunable disk usage measured with `du -sk`; default inclusive thresholds 8 entries or 2 GiB. | `A/AppFeature+Worktrees.swift:worktreeNotices,reloadStats` 66-77,397-417; `A/AppView.swift:toolbar notices` 106-119; `C/CanvasBand.swift:worktree chip` 59-77; `graphcode/Sources/Clients/GitClient.swift` 79-87,118-123; `K/WorktreeHygiene.swift:policy` 249-269; `T/WorktreeHygieneTests.swift` 281-307 (S/T). | **Observed** 9 Git worktree records including primary → **8** shown in lane and amber titlebar `Alpha · 8 reclaimable`; titlebar click opened scoped sweeper with 8 safe rows/33 KB and no primary checkout. After removing one linked fixture and refreshing, **7** shown and titlebar button absent. No 2 GiB, remote, partial/failed size or stale-state trial; those rules remain source/test only. | `eight-worktree-notice-original.png`, `seven-worktrees-no-notice-original.png`; full sweeper capture withheld because the UI displays a local recovery path | Fix Windows primary-checkout inclusion and logical-byte mismatch; preserve per-owner notice and honest incomplete/failure states. | High for local count boundary and sweep |
| Available update alert | Offers **Install Update / Release Notes / Later** with version/channel state. | `A/UpdateDialogs.swift:offer` 5-38; `A/AppFeature+Updates.swift:offer` 4-22; `graphcode/Sources/Clients/UpdateClient.swift:feed/channel` 7-73; `T/CheckForUpdatesTests.swift` (S). | **Not observed**: no release offer was obtained; no update network/release test was attempted. | none (release fixture) | Gate Install on actual Windows asset and retain offer through dismissal. | High (source), no release runtime |
| Install progress | Progress overlay and asynchronous Mac bundle swap into `/Applications`; fallback on failure. | `A/UpdateDialogs.swift:progress overlay` 104-119; `A/AppFeature+Updates.swift:install` 263-292; `graphcode/Sources/Clients/UpdateInstallClient.swift:install` 20-40,43-265; `T/UpdateInstallTests.swift` (S/T). | **Not observed**: update client tests passed in isolation, but no real release download or install. | none (release fixture) | Prove Windows download/swap phases on a real release, not Mac DMG implementation. | High (source/test), no installer runtime |
| Relaunch prompt | Successful install or external bundle replacement presents Relaunch Now/Later with workspace identity. | `A/UpdateDialogs.swift:ready/replaced` 47-58,123-174; `A/AppFeature+Updates.swift` 274-295; `graphcode/Sources/Clients/UpdateInstallClient.swift:relaunch` 313-340; `T/UpdateInstallTests.swift`, `T/UpdateQuitsOtherWorkspacesTests.swift` (S/T). | **Not observed**: no actual install, relaunch or daemon-backed terminal continuity trial; update tests alone do not establish it. | none (release/terminal fixture) | Verify running self-updater and restored session/daemon behavior with a real Windows asset. | High (prompt source), Low (runtime continuity) |
| Install failure | Failure alert gives reason, Download in Browser/Cancel and manual Mac install instructions. | `A/UpdateDialogs.swift:failure` 91-103; `A/AppFeature+Updates.swift` 263-270; `T/UpdateInstallTests.swift` (S/T). | **Not observed**: a unit test exercises fallback, but no real download, signature, permissions or swap failure was induced. | none (release failure fixture) | Provide Windows-specific recovery/failure reason, not Mac drag-to-Applications copy. | High (test/source), no live failure |
| UI Automation tree | Mac SwiftUI/AppKit provide AX defaults; custom Ghostty NSView text/focus conformance not established. | `G/GhosttyTerminalNSView.swift:custom NSView` 31-61; `A/AppView.swift:body` (S). | **Observed limited AX traversal**: native window, outline rows/static text, menu items/enabled state, sheet text/pickers/buttons were exposed. Several custom SwiftUI buttons/rows returned `name=missing value`; AX `click row` did not select Quick Chats, but a physical pointer click did. No exhaustive AX role/focus/live-region/terminal-text audit. | `empty-quick-chats-original.png` (result, not AX tree), `alpha-new-node-form-original.png` | Windows UIA should give all actionable controls stable labels and working Invoke/selection, not reproduce these Mac AX gaps. | Medium for sampled AX, Low for full tree |
| Keyboard discovery | Native commands declare visible key equivalents; app intercepts terminal zoom keys before Ghostty. | `A/GraphcodeCommands.swift:shortcuts` 5-14,63-166; `G/GhosttyTerminalNSView.swift:keyDown` 275-319; `T/MountFocusPolicyTests.swift` (S/T). | **Observed** native menu labels/state and `⌘K` in toolbar/`⌘T` in Templates; Return submitted the root rename prompt. App-wide key-equivalent dispatch and terminal collisions not tested. | `empty-global-graph-original.png`, `alpha-root-rename-prompt-original.png` | Show hints and prove focus-aware physical shortcuts in relevant contexts. | Medium for visible hints, Low for routing |
| IME/dead keys/layouts | Ghostty/AppKit implement marked text and composition ranges. | `G/GhosttyTerminalNSView.swift:keyDown,NSTextInputClient` 288-298,390-428 (S). | **Not observed**: keyboard entry used plain ASCII fixture text; no candidate window, dead key, non-US layout or terminal IME path. | none (IME/terminal fixture) | Exercise real composition and dead keys in forms and terminal. | Medium (source only) |
| Clipboard/selection | Selection forwarded to Ghostty; macOS selection clipboard support is disabled. | `G/GhosttyTerminalNSView+Mouse.swift:mouse/drag` 8-84; `G/GhosttyRuntime.swift:config` 61-70 (S). | **Not observed**: no terminal selection/copy/paste; no system clipboard modified during fixture work. | none (terminal fixture) | Validate Unicode copy/paste, multiline security and terminal vs global shortcuts live. | Medium (source only) |
| Per-monitor DPI | AppKit UI uses screen backing scale; terminal updates content/layer scale and framebuffer on change, coordinates stay points. | `G/GhosttyTerminalNSView.swift:init,viewDidChangeBackingProperties` 94-96,158-214; `G/GhosttyTerminalNSView+Mouse.swift:position` 89-104 (S). | **Observed app-owned shell** moved at constant **1400x820 logical** between ASUS 2x and Dell 1x and back; captured native PNGs at **3024x1864** (2x) and **1512x932** (1x), including variable capture shadows. Sidebar, lanes and controls remained visible. No terminal framebuffer/input test or pixel-equivalence claim. | `two-populated-project-lanes-original.png`, `two-populated-project-lanes-1x-original.png`, `two-populated-project-lanes-2x-return-original.png` | Maintain logical layout and update real render targets across monitors; still test terminal cell metrics/hit coordinates. | High for shell monitor move, Low for terminal |
| Dark visual language | App-owned graph/sidebar/cards/sheets use dark styling, native Settings is a separately styled grouped form; terminal theme may be user-overridden. | `A/Theme.swift:Theme` 3-110; `G/GhosttyAppearance.swift`; `T/GhosttyAppearanceTests.swift` (S/T). | **Observed** dark canvas/cards/new-node/edge/worktree sheets; **native Settings window is light**, not dark, in this build. Do not speculatively darken Windows native Settings for pixel parity. No light-mode variant of graph tested. | `alpha-new-node-form-original.png`, `alpha-new-edge-form-original.png`, `native-settings-default-original.png`; full worktree sheet withheld for privacy | Match intentional dark app-owned graph hierarchy while treating native settings/materials independently. | High for observed appearance |
| Font rendering quality | System UI/monospaced variants and Ghostty terminal font config; rasterization system/display-dependent. | `L/LoopWorkspacePanes.swift:font choices` 61-103; `G/GhosttyTerminalNSView.swift:font zoom` 98-105 (S). | **Observed samples only**: native UI/card/monospaced stats legible at 1x and 2x captures; no measured glyph quality/legibility threshold, terminal font/fallback or Windows-vs-CoreText comparison. | `two-populated-project-lanes-1x-original.png`, `alpha-handoff-fitted-original.png`, `native-settings-default-original.png` | Compare sizes/weights/contrast at matched logical geometry; never claim pixel-equal glyph rasterization. | Medium for samples, Low for parity |
| Line/shape anti-aliasing | SwiftUI/Canvas/Ghostty rasterization; no established quantitative AA criterion. | `P/NotebookGrid.swift:Canvas`; `P/CanvasEdgeViews.swift:EdgeLineView`; `G/GhosttyTerminalNSView.swift` (S). | **Observed samples only**: rounded cards, dashed Handoff curve and notebook grid at 1x/2x; no measured line smoothness or edge-style equivalence with Windows. | `alpha-handoff-fitted-original.png`, `two-populated-project-lanes-1x-original.png` | Compare actual representative path pixels on both platforms at same logical zoom/DPI, not color-count proxy. | Medium for samples, Low for parity |
| Color palette fidelity | Theme tokens and Ghostty sRGB background coupling; materials and display profiles alter composited pixels. | `A/Theme.swift:tokens` 31-110; `A/LoopStateAppearance.swift` 133-144; `G/GhosttyAppearance.swift:defaults` 20-76; `T/GhosttyAppearanceTests.swift` 8-58 (S/T). | **Observed samples only**: purple Composite, green Goal, amber blocked/notice and dark grid/card across two displays; no color-managed calibrated token/pixel comparison with Windows, no terminal override test. | `two-populated-project-lanes-original.png`, `alpha-handoff-fitted-original.png`, `eight-worktree-notice-original.png` | Share opaque owned tokens and compare controlled pixels; treat native glass/display profile separately. | High for source tokens, Low for pixel parity |

**Named examples from the 113 focused tests executed here:** `T/GraphOverviewTests.swift`:
`theGlobalGraphsOwnTriggersGetALaneThatIsNotNamedGraph()`,
`aGlobalGraphWithNoTriggersTakesUpNoRoomAtAll()`,
`aLanesCaptionCountsOffTheSameRollupTheMonitorReads()`; `T/NotebookGridTests.swift`:
`zoomingKeepsTheRulesUnderTheNodesTheyBelongTo()`; `T/CanvasTransformTests.swift`:
`zoomingKeepsWhatIsUnderThePointerUnderThePointer()`;
`T/WorktreeHygieneTests.swift`:
`theTitlebarNoticeAppearsOnlyPastAFoldersOwnThreshold()` and
`policyDecodesFromAnEmptyObjectWithDefaults()`;
`T/CreatedByLoopTests.swift`: `aChildInheritsItsCreatorsBackend()` and
`theHandoffIsRecordedAsAlreadyDoneSoTheNewLoopIsNotBlocked()`;
`T/LoopRenameTests.swift`: `renamingChangesTheTitleAndNothingElse()`;
`T/SketchPromotionTests.swift`: `promotingToGoalKeepsIdentityAndStartsRunning()`
and `promotingToGoalWithoutADoneCheckIsRefused()`;
`T/WorkspaceUpdateGatingTests.swift`:
`theDefaultWorkspaceIsTheOneThatManagesUpdates()`;
`T/UpdateInstallTests.swift`: `installDownloadsWithProgressAndOffersTheRelaunch()`
and `aFailedInstallExplainsItselfAndTheBrowserFallbackStillWorks()`;
`T/MountFocusPolicyTests.swift`: `inactiveSurfaceNeverClaims()`,
`neverTakesFromActiveSurface()`; `T/GhosttyAppearanceTests.swift`:
`theTerminalIsToldTheCanvasesOwnBackground()` and
`theTerminalBackgroundIsTranslucentButItsTextIsNot()`.
The run's passing `xcresult` covers the ten selected suites above, not every
test name in other source-only suites cited in the table. No test result
establishes live accessibility, IME, terminal renderer, provider persistence,
release installation or Windows parity.

## Verified macOS requirements

- **Runtime:** The 0.1.76/299 app maintains its sidebar while changing among
  welcome, global graph, Quick Chats, local project and nested Composite
  canvases. Two disposable projects simultaneously showed independent overview
  lanes, START/ENTRY topology, cards and a blocked rollup. The global lane
  remained empty and was omitted, as the source/test contract predicts.
- **Runtime:** The local node form exposes Main/Goal/Timed/Turn/Composite,
  Agent/Model/Branch; a real local worktree picker listed the main folder,
  existing linked worktrees and New branch. Goal and Composite validation
  blocked incomplete drafts. A physical connector drag opened a named New
  Edge sheet, and creating an ordinary unfired Handoff blocked its target.
  The cycle-guard form **visibly clipped** labels on this fixture; it is an
  observed defect, not a visual target.
- **Runtime:** Root Composite rename opened a named, prefilled alert and Return
  persisted the new title to project/global views. **Nested Main Rename… was
  offered but did not open the alert**, consistent with the reducer's
  root-only lookup (`P/ProjectFeature.swift:567-568`). Promotion uses another
  root-only lookup (`P/ProjectFeature.swift:702-715`), but was not invoked.
  Do not adopt the nested rename failure as intended parity.
- **Runtime:** Nine Git worktree records (one primary, eight linked) produced
  **eight** rows/33 KB in Alpha's scoped sweeper, an amber lane chip and an
  app toolbar notice. At seven linked worktrees the lane counted seven but
  the toolbar notice disappeared. The sweeper preselected eight safe rows;
  its full-window screenshot was withheld because its recovery note prints a
  local path; no deletion was triggered through the app. Actual source-level titlebar
  aggregation over *multiple threshold-breaching* projects remains untested.
- **Runtime:** The same 1400x820-point, current-build window was moved 2x→1x→2x
  with content and controls still present. The app-owned canvas, card, grid
  and most sheets were dark; **native Settings was light**. This establishes
  sample appearances, not quantitative AA, legibility, color or terminal DPI.
- **Source/tests:** The overview gives each project its own worktree summary;
  the toolbar considers all projects without summing them into a fake folder.
- Worktree inspection excludes the repository's canonical checkout **by
  path**, not by branch. All remaining assessed rows contribute to count,
  including prunable rows; only nonprunable rows contribute to size. Local
  and remote sizing run `du -sk`, then multiply KiB by 1024. Thresholds are
  inclusive 8 linked/detached worktrees **or** 2 GiB by default. Safe-tier
  reclaimability is a separate count. Disk-size publication and failed
  refresh can leave partial/stale displayed values, so no runtime freshness
  guarantee was established. Eight and seven local-count states **were** observed.
- **Source/tests only:** Existing edges have presentation/focus/delete rather
  than a post-creation edit command in the inspected menu. Ghostty owns VT
  rendering; background tabs are retained with focus gating. AppKit text
  composition and backing-scale callbacks exist. Mac updates have offer,
  progress, failure and relaunch states. None of those terminal, IME or real
  update outcomes was run in this fixture.

## Windows implementation candidates

These are bounded, independent candidates based on current Windows ledger
residuals, **not** a claim that Mac runtime parity was verified:

| Unit | Concrete next change or evidence gate | Likely Windows area and coordination |
|---|---|---|
| W1. Worktree semantics and ownership | Use the **captured 7/8 local threshold baseline**: exclude the canonical checkout, count assessed linked/detached entries, sum allocated `du -sk`-equivalent nonprunable usage. Compare Windows toolbar/lane/sweeper and action ownership on the same fixture; add separate 2 GiB, prunable, remote and partial/failure trials. Expose loading/stale status honestly rather than emulating macOS's transient false zero. | `WorktreeStatus.zig`, `GraphCanvas.zig`, `App.zig`, Git/process inspection and worktree dialogs; **overlap** with shared `GraphModel.zig`/`App.zig`. Do semantics before visual notice work. |
| W2. Graph editing fidelity | Compare real two-node Handoff creation, blocked state, Goal/Composite validation, root rename, nested scope addressing and guarded context actions against captures. Windows nested edit behavior should not copy macOS's no-op Rename; clarify whether Windows-only edge editing is an extension. Require save/reload/cancellation proof. | `EdgeCreation.zig`, `EdgeEditing.zig`, `SketchPromotion.zig`, `GraphContextMenu.zig`, node forms; serialize shared `App.zig` ownership with W1. |
| W3. Canvas and navigation evidence | Use the **captured two-populated-lane overview**, nested cards and grid at fixed 1400x820 with 1x/2x variants to prove live Windows paint/hit paths. Add actual pointer-anchored wheel/pinch, loop workspace and Show in Graph (not observed on Mac here). | `GraphCanvas.zig`, `Sidebar.zig`, `App.zig`, `TerminalSurface.zig`; overlaps W1 header/W2 canvas. Use stable fixtures. |
| W4. Terminal and input evidence | Run actual background PTY output while switching tabs/panes; select/copy/paste Unicode and dangerous multiline text; inspect accessibility text/selection, real IME/dead keys and monitor movement. | `TerminalWorkspace.zig`, `TerminalSurface.zig`, `Accessibility.zig`, native provider; needs interactive Windows hardware/desktop and may depend on W3 navigation fixture. |
| W5. Codespace end-to-end | With explicit authorized Codespaces access only, drive real discovery, selection, path validation, retry/error and remote open. Do not expand scope or acquire permissions for the test. | `Codespaces.zig`, `WindowsCodespaceDialog.zig`; external auth/provider prerequisite, otherwise retain Partial. |
| W6. Release update lifecycle | Publish/identify a real Windows asset through normal release process, then run offer → download/checksum/extract → upgrade of a **running** process → Later/Relaunch/restore and failure/browser recovery. | `WindowsUpdates.zig`, `WindowsUpdateInstall.zig`, `UpdateInstallDialog.zig`; requires real asset and releaser decision; do not synthesize successful release evidence. |
| W7. Controlled visual/AX comparison | The current-build Mac **1x/2x original captures are now available**. Capture Windows at same logical sizes/states; compare opaque Theme-owned tokens, cards/edges/grid, sheets, menu hints and accessible roles. Native Mac Settings is light; AX sample buttons were unlabeled, so fix Windows UIA on its own merits rather than copying that gap. Do not claim byte-identical entire-window pixels. | `DesignTokens.zig`, `GraphCanvas.zig`, `Accessibility.zig`, native forms; depends on W3 fixture and compatible Windows captures. |

**Recommendation:** Start W1 on the now-measured 7/8 notice boundary and W2
on the connector-drag/blocked-card fixture without new auth or release scope.
Serialize their shared `App.zig`/`GraphModel.zig` edits. Mac captures unblock
W3/W7 visual comparisons but do **not** validate corresponding Windows paths.
Keep the ledger's rows Partial until source mapping, tests and real Windows
walkthrough agree for each full row.

## Prerequisites and blockers

| Category | Blocker / resolution |
|---|---|
| Environment/access resolved here | An isolated current-SHA build, pinned submodules/dependencies, macOS 15.5 Zig SDK, scoped temporary daemon/socket, screen capture/AX permission, two disposable Git projects and mixed-DPI displays were provided. No edits occurred in the original worktree and no LaunchAgent was installed. To repeat, use the same SHA/version and *disposable* state; do not run the older DerivedData app or point at the user's normal support directory. |
| Environment/access still needed | To validate real mounted terminals and Show in Graph, use an explicitly permitted provider/PTY fixture and safe CLI credentials/config (not obtained here). To validate native IME, require permitted keyboard layouts/input methods. The observed nested Rename no-op and edge-cycle form clipping are macOS findings needing separate product follow-up, not permission failures. |
| External prerequisites | Separately authorized authenticated Codespaces access and remote `zmx`; a real macOS offer plus real Windows release artifact for install/relaunch/failure; touch/precision hardware if gesture paths are claimed. No account/provider was provisioned. |
| Blocked only on Windows-side live evidence | Mac now has bounded live shell, graph, form, 7/8-worktree and 1x/2x visuals. Windows still needs equivalent real fixture/UIA and input proof for those rows. Native terminal/IME/updates remain unobserved on **both** sides as applicable. |
| Explicit scope decisions | Windows-only edge editing is beyond current Mac UI; Windows touchscreen pan, remote/global branch picker visibility, clipboard confirmation UX and platform-native update/browser/material behavior need product decisions instead of assumed pixel parity. |

## Not verified

These parts of the requested behavior were **not verified**, not found absent:

- Loop workspace/terminal toolbar and detail panel; actual Shortcut dispatch
  beyond Return in rename; workspace create/rename/delete and second-window
  activation; real needs-you titlebar chip, global titlebar multi-owner order.
- A **populated** global-trigger lane; remote/cross-project worktree inspection,
  byte threshold, prunable/partial/failed/stale sizes; actual connected-card
  context hit, fired/guarded/message/spawn presentation and cycle execution.
- Node custody creation, resolved-parent exclusion, nested promotion, typed
  retype, delete confirmation, edge deletion, daemon save/reload after exit;
  physical trackpad/wheel/pinch pan and pointer anchor. A root rename was
  confirmed; nested Rename was **observed not to open**, not simply untested.
- Ghostty VT glyphs/styles/cursor/scrollback, background process and tab
  persistence, Show in Graph effects, terminal AX text/selection, IME/dead
  keys/layouts, Unicode copy/paste and security prompts. No provider ran.
- Authenticated Codespaces discovery/select/dial; real macOS update offer,
  install progress/relaunch/failure/session continuity; objective font/AA/
  color-management thresholds. A 1x↔2x **shell** transition was observed;
  the terminal-specific framebuffer/cell path was not.

Do not generalize source/test or sample PNGs into these missing interaction
claims. Permission and build provenance are **no longer** blockers for
app-owned screenshot/AX trials; fixture and scope boundaries are.

## Artifact index

Machine-readable Markdown index of **original, unedited** window-capture PNGs.
Dimensions are the complete PNG, including compositor shadow/sheet margins;
they are **not** equivalent to the logical app window dimensions. Screenshots
of the same 1400x820 logical window can be 2936x1776 or 3024x1864 on 2x
because the capture margin changes; do not rescale or compare raw full-image
pixel coordinates without first measuring the window content bounds. Dynamic
elapsed values and native materials also vary between captures. `none` rows
record requested surfaces with no original capture, not a product absence.
All captured content uses generic disposable fixture names and contains no
access tokens, real project names, user names, or absolute host-local paths.

| Ledger row | Artifact filename | Capture scenario | Resolution/scaling | Demonstrates |
|---|---|---|---|---|
| Main split view | `isolated-window-a-original.png` | first-run onboarding over isolated empty shell | PNG 1936x1480, 2x | Native onboarding/shell; not a real graph fixture |
| Main split view | `empty-welcome-original.png` | isolated debug app before temporary daemon connected | PNG 1936x1184, 2x | Persistent sidebar, empty welcome and Jump |
| Main split view | `empty-global-graph-original.png` | connected daemon, no project | PNG 1936x1184, 2x | Graph row, notebook grid and empty action |
| Main split view | `empty-quick-chats-original.png` | Quick Chats destination, connected, no chats | PNG 1936x1184, 2x | Sidebar retained, Quick Chats empty detail |
| Main split view | `alpha-empty-project-original.png` | Alpha local Git project, no loops | PNG 1936x1184, 2x | Project-scoped empty detail/templates |
| Main split view; Cross-project global graph | `alpha-composite-empty-original.png` | unpiloted Alpha Composite opened | PNG 1936x1184, 2x | Nested breadcrumb and empty group |
| Node creation sheet; Keyboard discovery | `alpha-new-node-form-original.png` | Main sheet before creating node | PNG 2024x1448, 2x | Type teaching, default backend/model/branch and Start |
| Node creation sheet | `alpha-composite-form-original.png` | Composite type selected, name empty | PNG 1936x1360, 2x | Disabled Create & open, “Nothing runs…” instructions |
| Node creation sheet | `alpha-goal-validation-original.png` | Goal type, missing done description | PNG 3024x1864, 2x | Validation reason and Goal-specific fields |
| Loop card identity | `alpha-nested-two-nodes-original.png` | inert Goal + Main in unpiloted Alpha group | PNG 2936x1776, 2x | Green/white stripes, IDLE, unwired entry roles |
| Edge creation sheet | `alpha-new-edge-form-original.png` | physical connector Goal→Main drag | PNG 2936x1776, 2x | Named endpoints, Handoff/Always/Nothing defaults |
| Edge creation sheet | `alpha-edge-cycle-controls-original.png` | loop-back toggle enabled in New Edge | PNG 2936x1776, 2x | Max 3/stop/plateau controls and observed clipping |
| Edge presentation; Edge creation sheet | `alpha-created-handoff-original.png` | Create default Handoff in unpiloted group | PNG 2936x1776, 2x | Dashed edge, new BLOCKED target; right card partly clipped |
| Edge presentation; Loop card identity | `alpha-handoff-fitted-original.png` | press Fit after Handoff creation | PNG 2936x1776, 2x | Both cards, dashed Handoff, blocked target in view |
| Node update/rename | `nested-rename-no-dialog-original.png` | after nested Main Rename… popup action | PNG 3024x1864, 2x | No alert after action; needs AX/source trace to establish attempted invocation |
| Node update/rename | `alpha-root-rename-prompt-original.png` | root Composite Rename… | PNG 2936x1776, 2x | Prefilled title, consequence copy and Cancel/Rename |
| Cross-project global graph; Worktree notice chip | `two-project-overview-original.png` | after switching from nested to overview, before Fit | PNG 2024x1272, 2x | Sidebar/graph present; lanes offscreen until recenter |
| Cross-project global graph; Pan and anchored zoom | `two-project-overview-fitted-original.png` | click Fit at 900x524 logical | PNG 1936x1184, 2x | Alpha card + empty Beta lane at 36% |
| Cross-project global graph; Notebook grid | `two-project-overview-1400x820-original.png` | same overview after resizing to 1400x820 | PNG 2936x1776, 2x | Alpha card/empty Beta lane, grid at 63% |
| Worktree notice chip; Window toolbar | `eight-worktree-notice-original.png` | Alpha: one primary + eight linked Git entries | PNG 3024x1864, 2x | Amber titlebar and lane notices at inclusive count 8 |
| Worktree notice chip | none | scoped sweeper invoked from titlebar | N/A | AX observed 8 safe rows/33 KB; full-window capture withheld due local recovery path in product copy |
| Worktree notice chip; Window toolbar | `seven-worktrees-no-notice-original.png` | remove one disposable linked worktree then refresh | PNG 3024x1864, 2x | Lane says 7, titlebar notice absent |
| Cross-project global graph; Loop row presentation | `two-populated-project-lanes-original.png` | Alpha and Beta each have one Composite | PNG 3024x1864, 2x | Two START/project lanes, blocked/idle rollups, sidebar age |
| Workspace lifecycle | `manage-workspaces-original.png` | File > Workspace > Manage, before dismissal | PNG 3024x1864, 2x | Default vs active runtime workspace status and Done |
| Dark visual language; Font rendering quality | `native-settings-default-original.png` | product Settings window, no config changed | PNG 2024x1124, 2x | Native light grouped form alongside dark app chrome |
| Per-monitor DPI; Color palette fidelity | `two-populated-project-lanes-1x-original.png` | 1400x820-point overview moved to Dell 1x | PNG 1512x932, 1x | Graph/sidebar/card paint survives monitor change |
| Per-monitor DPI; Line/shape anti-aliasing | `two-populated-project-lanes-2x-return-original.png` | same window back on ASUS 2x | PNG 3024x1864, 2x | Controls remain present after 1x→2x return |
| File/Loop/Terminal menus | none | native menu bar read via AX | N/A | Labels/enabled recorded in findings; no menu-window capture |
| Custody child creation | none | unresolved node context action read via AX | N/A | Custody creation itself not invoked |
| Edge editing | none | attempted edge popup hit folder background | N/A | No edge edit UI claimed from runtime |
| Canvas context menu | none | card/folder popup items read via AX | N/A | Context menu text/enablement recorded, not pixels |
| Sketch promotion | none | Main popup submenu read via AX | N/A | No promotion form/submit captured |
| Terminal VT state and rendering | none | no provider session | N/A | Terminal VT and rendering untested |
| Mounted background tabs | none | no provider session | N/A | Live process retention untested |
| Show in Graph | none | menu disabled without terminal workspace | N/A | Navigational action untested |
| Add Codespace sheet | none | no authorized Codespaces access | N/A | Discovery-success/dial untested |
| Available update alert | none | no release offer | N/A | Update offer untested |
| Install progress | none | no release install | N/A | Progress untested |
| Relaunch prompt | none | no completed update | N/A | Restart/continuity untested |
| Install failure | none | no failed release install | N/A | Live recovery untested |
| UI Automation tree | none | AX traversal via System Events | N/A | Text observations in findings; no tree screenshot |
| IME/dead keys/layouts | none | ASCII-only form input | N/A | Real composition untested |
| Clipboard/selection | none | no terminal/copy operation | N/A | Paste/selection untested |
