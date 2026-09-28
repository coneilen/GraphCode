# macOS parity capture originals

All PNGs in this folder are **unaltered window-specific screenshots** of an
isolated GraphCode 0.1.76 (299) build from commit
`717240cdb373a2c00644842c429f06e520d15f51` on macOS 26.7, captured
2026-09-28 PDT. Only disposable Alpha/Beta local Git repositories and a
temporary, unregistered daemon were used. No real project, provider, account
or update was opened. The report at
`../macos-parity-evidence-report.md#artifact-index` supplies **one row per
original** with ledger mapping, exact PNG dimensions, logical capture window
size, display scaling and the bounded claim each image supports.

| Ledger surface | Original filenames |
|---|---|
| Main split view, welcome, global/Quick Chats/project empty states | `isolated-window-a-original.png`, `empty-welcome-original.png`, `empty-global-graph-original.png`, `empty-quick-chats-original.png`, `alpha-empty-project-original.png` |
| Workspace lifecycle | `manage-workspaces-original.png` |
| Global graph, lane/card layout, notebook grid and loop rows | `two-project-overview-original.png` (pre-Fit/offscreen), `two-project-overview-fitted-original.png`, `two-project-overview-1400x820-original.png`, `two-populated-project-lanes-original.png`, `alpha-composite-empty-original.png` |
| Node creation and validation | `alpha-new-node-form-original.png`, `alpha-composite-form-original.png`, `alpha-goal-validation-original.png`, `alpha-nested-two-nodes-original.png` |
| Edge creation and presentation | `alpha-new-edge-form-original.png`, `alpha-edge-cycle-controls-original.png` (observed form clipping), `alpha-created-handoff-original.png`, `alpha-handoff-fitted-original.png` |
| Node rename | `nested-rename-no-dialog-original.png` (post-click; see report for AX/source context), `alpha-root-rename-prompt-original.png` |
| Worktree notice boundary | `eight-worktree-notice-original.png`, `seven-worktrees-no-notice-original.png` |
| Native appearance | `native-settings-default-original.png` (light Settings versus dark app) |
| Per-monitor DPI and sample visual fidelity | `two-populated-project-lanes-1x-original.png`, `two-populated-project-lanes-2x-return-original.png` |

The 900x524 and 1400x820 figures refer to **logical app window points**.
PNG dimensions include variable shadow/sheet margins. The ASUS display uses
2x (3840x2160 physical, 1920x1080 logical); the Dell uses 1x
(1920x1080 physical/logical). Changes in elapsed labels, selection, and
native material prevent unqualified whole-image pixel comparisons.

Menus were inspected via macOS Accessibility rather than photographed outside
the app window. The worktree sweeper was also inspected via Accessibility:
its full-window capture was withheld because the product's recovery note
displays a local path. No runtime evidence was fabricated for terminal-backed
tabs, Codespaces, IME/clipboard, or a real update. The 113 focused Swift tests
are described in the report; screenshots are **not** screenshots of those tests.
