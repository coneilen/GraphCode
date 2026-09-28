# macOS GraphCode parity evidence collection

You are the macOS-side evidence researcher for the Windows GraphCode parity effort in `scgopi/GraphCode`. Your task is to give the Windows implementation team accurate, current, reproducible evidence of what the macOS app actually does and looks like. Do not implement changes or modify the shared repository.

## Goal

Review the current `investigation/ui-parity-matrix.md` in the repository, then collect macOS source and runtime evidence that will help resolve its remaining `Partial` rows. The Windows team needs to know which gaps are real product differences, which are only missing evidence, what macOS behavior is authoritative, and what visual comparison can be made.

Do not treat the ledger as infallible or infer behavior from a row title. Check the current macOS implementation and, where possible, exercise the app. Record the exact app version/build, macOS version, repository commit, display scaling/resolution, and any fixture or setup used.

## Scope and constraints

- Work read-only in the repository. Do not edit source, tests, the ledger, project settings, release workflows, or credentials.
- Do not provision providers, services, accounts, GitHub scopes, or other infrastructure.
- Do not expose access tokens, private repository contents, user names, local paths, or other secrets in your report or captures. Redact them while preserving the behavior being demonstrated.
- Do not claim a behavior is absent merely because it was not reachable in your environment. Mark it **not verified** and explain the limitation.
- Distinguish clearly between source inspection, automated test evidence, and behavior actually observed in the running macOS app.
- Capture screenshots or short recordings only when permitted in your environment. Prefer screenshots for static appearance and brief recordings for interactions. Include unedited originals; do not retouch, recolor, or annotate the evidence images. Put explanatory notes in the report instead.
- If live capture is blocked by permissions, missing fixtures, unavailable services, or lack of a suitable device, report the exact blocker and still provide source-level findings for the affected rows.
- Do not ask for, copy, or send credentials. If an authenticated feature cannot be tested, document the missing capability by name without including credential material.

## Rows to investigate

Use the current ledger as the source of truth. At minimum, address each currently `Partial` row below; if a row's status or wording has changed, follow the current ledger and note that difference.

### Shell, navigation, and graph

- Main split view
- Window toolbar
- File/Loop/Terminal menus
- Workspace lifecycle
- Loop row presentation
- Cross-project global graph
- Notebook grid
- Pan and anchored zoom
- Loop card identity
- Worktree notice chip

### Graph editing and node workflows

- Edge presentation
- Edge creation sheet
- Custody child creation
- Edge editing
- Node creation sheet
- Node update/rename
- Canvas context menu
- Sketch promotion

### Terminal workspace

- Terminal VT state and rendering
- Mounted background tabs
- Show in Graph

### Ingress and updates

- Add Codespace sheet
- Available update alert
- Install progress
- Relaunch prompt
- Install failure

### Accessibility, input, and visual fidelity

- UI Automation tree
- Keyboard discovery
- IME/dead keys/layouts
- Clipboard/selection
- Per-monitor DPI
- Dark visual language
- Font rendering quality
- Line/shape anti-aliasing
- Color palette fidelity

Do not spend time revalidating unrelated `Validated` rows except where they provide a useful control or shared interaction context.

## Evidence to collect for each row

For every row, provide a compact entry containing:

1. **macOS behavior:** exact visible controls, labels, state, actions, keyboard/mouse/trackpad behavior, confirmation/error states, and important edge cases.
2. **Source references:** file path and symbol (plus line numbers if convenient) that implement the behavior. Include tests and test names when present. Do not paste large source excerpts.
3. **Runtime result:** `Observed`, `Not observed`, or `Not applicable`, with a short explanation and any setup/fixture. Separate direct observation from conclusions based on source or tests.
4. **Evidence artifact:** screenshot/recording filename and what it proves, or an explicit reason one could not be captured. Capture the whole relevant window where possible, with enough context to identify the surface.
5. **Parity implication:** what Windows must expose or do to match the macOS behavior, phrased as a specific observable/actionable requirement. Identify true platform-specific differences separately from product behavior.
6. **Confidence:** High, Medium, or Low, with a brief rationale.

Prioritize the concrete residuals already called out by the Windows ledger:

- Which worktree counts, size semantics, ownership, and aggregation rules are used by macOS; what appears in the titlebar, project canvas, and global graph; and how stale, partial, failed, or uninspected data is presented.
- Exact node/edge editing, creation, rename, deletion, sketch-promotion, and custody-child behavior, including eligibility, confirmations, field defaults, validation, cancellation, and persistence.
- Whether background terminal tabs preserve mounted terminal processes and selection/state; what Show in Graph does to selection, navigation, and workspace state.
- Exact keyboard shortcuts, menu placement, context-specific availability, discoverability hints, focus behavior, accessibility labels/roles/actions, and selection announcements.
- Touch/trackpad pan, wheel and pinch zoom, anchor behavior, and the macOS grid/canvas relationship.
- DPI/Retina and appearance behavior, typography/font choices, antialiasing, color tokens, gradients/materials, and any platform-native controls that intentionally differ.
- Update offer and install/relaunch/failure behavior if a macOS release flow is available; do not infer that the Windows implementation should copy a different platform's installer design.

## Visual comparison protocol

Where practical, capture the same scenarios at the same logical window size and comparable display scaling:

- Main shell with sidebar and each relevant detail destination.
- Global graph with at least two projects and enough loops to show lane/card layout.
- Project canvas with cards, edges, labels, and context menus.
- Loop workspace with multiple tabs, split panes, selected tab, and detail panel states.
- Settings and representative native sheets/forms, including validation/error states.
- At least one light/dark or appearance variant if supported.

For every capture, record the window dimensions and display scaling. Keep screenshots at native resolution. Do not claim pixel equivalence from differently sized or scaled images. If macOS behavior is dynamic or fixture-dependent, note the state and fixture clearly.

## Deliverables

Return a concise report as a Markdown file named `macos-parity-evidence-report.md`, plus an `evidence/` folder containing the original screenshots/recordings and a short `README.md` mapping each artifact to the ledger row it supports. Deliver these as downloadable/attached artifacts or in a location explicitly shared with the Windows coordinator; do not commit them to `main`.

The report must include:

- Repository URL and inspected commit SHA.
- GraphCode version/build, macOS version, display resolution/scaling, and capture date/time with timezone.
- A row-by-row findings table with the six evidence fields above. Use one entry per current Partial row; do not merge separate rows into a vague subsystem summary.
- A **verified macOS requirements** section listing behavior supported by source/runtime evidence.
- A **Windows implementation candidates** section grouping actionable changes into independent, bounded units; include likely source areas only when you can establish them from the repository. Flag overlaps and ordering dependencies.
- A **prerequisites/blockers** section separating:
  - environment/access blockers the coordinator could resolve,
  - external prerequisites (for example a real release artifact or permitted authenticated Codespaces access),
  - rows blocked only on Windows-side live evidence,
  - intentional Windows scope exclusions that require an explicit scope decision.
- A **not verified** section listing every requested behavior you could not exercise and why.
- A machine-readable artifact index in Markdown with: ledger row, artifact filename, capture scenario, resolution/scaling, and what the artifact demonstrates.

Be decisive but evidence-led: recommend the next Windows parity units that can proceed without changing existing scope boundaries. Do not label the Windows parity effort complete.
