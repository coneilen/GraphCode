# macOS parity evidence

Reference evidence captured from the **shipping macOS app** so the Windows port
has an authoritative comparison target for the `Partial` rows in
[`../ui-parity-matrix.md`](../ui-parity-matrix.md).

It was produced by running
[`../macos-parity-evidence-agent-prompt.md`](../macos-parity-evidence-agent-prompt.md)
on a macOS host.

| | |
| --- | --- |
| App build | GraphCode 0.1.76 (299) |
| Built from | `717240cdb373a2c00644842c429f06e520d15f51` |
| Host | macOS 26.7 (25G229), Apple Silicon |
| Captured | 2026-09-28 PDT |
| Displays | 3840x2160 physical / 1920x1080 logical (2x); 1920x1080 (1x) |

## Contents

- [`macos-parity-evidence-report.md`](macos-parity-evidence-report.md) — row-by-row
  findings for the 35 `Partial` rows, verified requirements, Windows
  implementation candidates (W1–W7), blockers, an explicit *Not verified* list,
  and an artifact index.
- [`evidence/`](evidence/) — 26 unaltered window screenshots, indexed by the
  report. `evidence/README.md` maps them to ledger surfaces.

## How to read it

The report marks every claim with `S` (inspected source), `T` (test source), or
`R` (direct observation of the running app), and rates confidence on the
**bounded** finding rather than on blanket platform equivalence. Ten Swift
suites were executed once — 113 passed, 0 failed, 0 skipped. That is focused
automated evidence, not a full `make test`.

Read the report's *Not verified* section before citing anything. Terminal VT
output, IME, clipboard, Codespaces and a real update were deliberately **not**
exercised, and are recorded as unobserved rather than absent.

## What this evidence does and does not do

It **does** establish macOS behavior that Windows work can be measured against,
and it supplies fixed-size 1x/2x captures for visual comparison.

It **does not** validate any Windows code path. A ledger row still requires its
own Windows runtime evidence before it can leave `Partial`, and citing this
report is not a substitute for that.

Two observed macOS behaviors are **defects, not parity targets**, and must not
be copied:

- Nested Main `Rename…` is offered but does not open the rename alert
  (root-only lookup in `ProjectFeature.swift`).
- The edge cycle-guard form visibly clips its labels on this fixture.

Accessibility sample buttons were also found unlabeled on macOS; fix Windows UIA
on its own merits rather than matching that gap.

## Provenance and hygiene

Captures are unaltered and unannotated. Only disposable `Alpha`/`Beta` Git
repositories, an isolated bundle ID and a temporary unregistered daemon were
used; no real project, account, provider, Codespace or release was opened. The
worktree sweeper's full-window capture was deliberately withheld because the
product's recovery note renders a local path.

Do not retouch, recompress or crop these files. Their evidentiary value depends
on being byte-for-byte what the app rendered. Add new captures alongside them
rather than replacing them.
