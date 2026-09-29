## Summary

<!-- What does this PR do? One or two sentences. -->

## Changes

<!-- Bullet list of changes. -->

-

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

RED: <focused command> -> <failure proving the behavior was missing>
GREEN: <same focused command> -> pass
REGRESSION: <adjacent/full command> -> pass

## Checklist

- [ ] I have read the [Contributing Guidelines](../CONTRIBUTING.md)
- [ ] I have signed off my commits (`git commit -s`) per the DCO
- [ ] Tests pass locally (`make test`)
- [ ] Code follows the existing style (`make check`)
- [ ] I added the test/contract before the implementation and observed the intended RED failure
