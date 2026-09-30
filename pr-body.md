## Summary

Add isolated `-ReferenceSet` capture support for the Windows visual-baseline harness, with static regression contracts for the context-menu, node-form, settings-inspection, and workspace capture paths. This is evidence-enablement only; it does not add a complete or accepted Windows reference set.

## Changes

- Extend the existing harness to capture native context menus and node-form states while recording exact image/window provenance and fail-closed source/provider/binary consistency.
- Add static contracts that verify the new mode is forwarded to the worker and that capture paths use the owned native UI actions.
- Preserve partial capture outputs outside the repository. No rendered baseline PNGs or `evidence.json` are included because the foreground guard prevented completion.
- Leave the historical focus-tint evidence, provider pins, and parity ledger unchanged.

## Test plan

<!--
How did you verify this works?

The three lines below are checked by Tools/tdd/Test-TddEvidence.ps1 on every open,
edit, synchronize and reopen. Replace each one entirely. Each must:

  - use `command -> result` form, with a literal ` -> ` separator
  - be at least 8 characters after the label
  - contain NO angle brackets ANYWHERE on the line, including inside file paths
  - not contain TODO, TBD, or N/A

The angle-bracket rule is the one that actually bites. It applies to the whole line,
not just to the scaffolding below, so abbreviating a long path as an angle-bracketed
token is rejected exactly like an unedited placeholder. Write the real path, or
shorten it without brackets (...\winghostty\include, or a repo-relative path).

Worked example, with the labels deliberately not at the start of a line so the
checker does not read this comment as your evidence:
  e.g. RED: zig test src\Foo.zig --test-filter "grid" -> expected 60, found 120
  e.g. GREEN: zig test src\Foo.zig --test-filter "grid" -> 1/1 passed
  e.g. REGRESSION: zig test src\Foo.zig -> 71/71 passed

Keep the real failure text on the RED line. Do not replace it with a passing run,
and note that a compile error is not evidence of runtime behavior.
-->
RED: pwsh -NoProfile -File Tools\windows\capture-visual-baseline.ps1 -Shell .\graphcode-windows\zig-out\bin\graphcode-windows.exe -Zmx .\.graphcode-tools\providers\zmx\zig-out\bin\zmx.exe -OutputDirectory C:\Users\coneilen\.copilot\session-state\5bcb40ff-a88b-4bfb-b248-5a4da1c983ef\files\reference-run-8 -ForegroundLease coordinator-authorized-exclusive-capture -ReferenceSet -> failed: Could not foreground owned workspace-single-pane-disconnected; setForeground=False
GREEN: pwsh -NoProfile -File Tools\windows\Tests\VisualBaseline.Tests.ps1 -> VisualBaseline.Tests.ps1: PASS; ReferenceSet capture contract: PASS
REGRESSION: pwsh -NoProfile -File Tools\windows\Tests\VisualBaseline.Tests.ps1 -> VisualBaseline.Tests.ps1: PASS; five exact RGB mutation boundaries rejected

The capture run is not a parity result: zero images are accepted. Eight provisional images from the bounded retry are preserved in the session artifact directory; they are not committed. The attempt used Winghostty `f5abc059e4ca58b376eb209313aca7784659c679` and zmx `785b3fd15dcafd1882b495c831a10f98c201b908`. It did not produce `evidence.json`, replay output, or a replay mutation-failure result. Supervisor cleanup verified zero remaining owned PIDs.

## Checklist

- [x] I have read the [Contributing Guidelines](../CONTRIBUTING.md)
- [x] I have signed off my commits (`git commit -s`) per the DCO
- [ ] Tests pass locally (`make test`)
- [ ] Code follows the existing style (`make check`)
- [ ] I added the test/contract before the implementation and observed the intended RED failure
