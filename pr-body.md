## Summary

The hosted Windows UIA gate now measures right-click context menus on the blank canvas, a loop card, and a graph edge using live canvas geometry and native HMENU contents.

## Changes

- Assert ordered, target-specific menu items plus enabled and checked state for all three canvas targets.
- Verify the edge editor opens for the fixture edge and can be cancelled without sending a daemon command.
- Emit observed menu items, identities, coordinates, and outcomes as structured UIA evidence.

## Test plan

RED: hosted run 36678446642 job 109768495509 step 10 -> canvas background context menu unexpectedly omitted node-only Open Terminal (command 5104)
GREEN: hosted run 36678446642 job 109768495509 step 10 -> corrected assertion pending a new hosted run
REGRESSION: pwsh -NoProfile -File Tools\windows\Tests\ValidationRunner.Tests.ps1 -> ValidationRunner.Tests.ps1: PASS; PowerShell Parser::ParseFile and git diff --check passed

The local checks are static only; the live UIA walkthrough is exercised by the hosted Windows shell integration job.

## Checklist

- [x] I have read the [Contributing Guidelines](../CONTRIBUTING.md)
- [x] I have signed off my commits (`git commit -s`) per the DCO
- [ ] Tests pass locally (`make test`) — not run; this change is limited to the Windows UIA gate and static contract
- [x] Code follows the existing style
- [x] I added the test/contract before the implementation and observed the intended RED failure
