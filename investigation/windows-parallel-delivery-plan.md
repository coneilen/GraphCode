# Windows preview and parity: parallel delivery plan

**Status:** Reviewed proposal for tracking; implementation pending.
**Date:** 2026-10-01.

## Recommendation

An engineer starts a coordinator on each participating PC, without selecting
individual tasks. Each coordinator selects suitable ready issues, claims them
globally, launches independent local workers, follows their PRs through review
and merge, and then fills the freed task slots from the backlog.

Keep GitHub issues as the backlog and the existing documents as acceptance
sources. Add only the synchronization needed for autonomous dispatch: a small
atomic claim helper and enforced local exclusion for live tests. Do not build
a separate scheduling service.

This revises the earlier manual-allocation proposal. Ownership comments alone
were adequate for explicit human allocations, but are not enough when multiple
coordinators independently select work across engineers and PCs.

The plan incorporates two ordered review passes for validity and simplicity,
staged App refactoring, multi-PC execution, and unattended progression after
merge. The coordinator and claim helper are proposed, not implemented by this
document. Tracking the plan does not authorize installations or publication.

## Goals and acceptance sources

Deliver the narrow Windows preview as soon as its actual production workflow is
qualified, while independently progressing full macOS parity.

- [Windows preview-readiness plan](windows-preview-release-plan.md) defines
  preview scope and the seven release gates.
- [Windows UI parity ledger](ui-parity-matrix.md) defines visible equivalence and
  the evidence required to mark a surface `Validated`.
- `CONTRIBUTING.md` and `AGENTS.md` govern contributions, scope, isolation,
  sign-off, tests, and evidence.

The planning snapshot is main commit `962990a8`: 98 ledger surfaces, with
62 `Validated` and 36 `Partial`. Refresh these counts and existing issue/PR
activity when preparing the backlog. They are not certification of a packaged
production-agent experience.

Preview qualification does not require completing every Partial row. It does
require a usable local production flow with one named, actually tested agent
backend, safe mutations, persistence, and installation/recovery. Deferred
features must remain safe and honestly presented. Full parity retains the
ledger's stricter whole-surface acceptance criteria.

## 1. Create a flat, actionable backlog

Cover all outstanding work in both documents, including residual requirements
and infrastructure notes outside their tables. Do not mechanically create one
implementation issue for every surface, or require a parent/child hierarchy for
every task.

One execution issue should describe a coherent outcome that an engineer can
hand to an agent. An implementation task normally produces one scoped PR;
a qualification task may instead produce retained evidence and a documentation
PR. Split tasks when their ownership, dependencies, or deliverables are genuinely
independent, not merely to increase the issue count.

### Backlog preparation

1. Read each outstanding requirement and check existing issues and open PRs.
2. Reuse a suitable issue; otherwise create one using the repository's issue
   templates and preserve their sections.
3. Add source-document/surface links, scope, acceptance criteria, relevant
   dependencies, and expected files to the issue body.
4. Group the work into preview-critical, full-parity, and engineering-enablement
   sections in the existing Windows umbrella issue.
5. Add issue references to the relevant document requirements so coverage can
   be reviewed without maintaining a second mapping database.

Every outstanding requirement should point to actionable work, including
explicitly deferred work. The 62 Validated surfaces need relevant regression
coverage in the release flight, not automatically new implementation tickets.

Use `windows` on these issues. Proposed additional labels are `preview`,
`parity`, `windows-ready`, and `blocked`; create them during backlog preparation,
not as an implied action of this draft. Use the earliest release need for
prioritization; an issue can contribute to both preview and parity.

`windows-ready` is the maintainer's opt-in to autonomous dispatch by participating
engineers. It means scope and acceptance are bounded, operational metadata is
present, and any assignee change on a successful claim is authorized. It does
not mean dependencies have already passed; coordinators check those live.
Do not make existing assigned work dispatchable without this agreement.

Keep F/O/P/E distinctions in the source documents or issue descriptions when
they clarify scope. Do not reproduce them as a large custom-field taxonomy.
A simple GitHub Project is optional if the issue list becomes difficult to scan.

An agent-ready issue needs:

- The behavior or evidence to deliver, and its source requirement.
- Scope and exclusions, including likely shared files.
- Observable acceptance criteria and the required evidence level.
- Blocking issue/PR links, where a real prerequisite exists.
- A small machine-readable scheduling block: priority, dependencies, edit
  scopes, and required capabilities. Use a fixed, validated format so workers
  do not guess dependencies or exclusive scope from prose.

Example scheduling block, not a claim or authorization to execute:

```yaml
priority: high
depends_on: []
edit_scope: [bootstrap]
needs: [windows-build]
```

Define a short shared vocabulary for scopes and capabilities during preparation.
Missing or invalid metadata makes an issue ineligible, with an explicit reason.
These fields are for dispatch, not a second copy of the parity ledger or a
large Project schema.

Dependency completion is not inferred from an issue being closed. For an
implementation prerequisite, verify its recorded PR merged into the required
target and the landed change satisfies the prerequisite. For a qualification
prerequisite, verify accepted evidence for the required candidate/profile.
Previously completed manual work can supply the same recorded outcome; it does
not need an old coordinator claim.

Existing manual ownership and active PRs must be reconciled before adding the
ready label. Coordinators also check them before starting; assignment alone is
not proof of an active execution.

Participating manual work must use the same helper before editing a declared
contended scope. The ready label controls automatic dispatch, not scope
protection. The protocol cannot prevent an out-of-process editor from ignoring
this rule; do not represent cooperative reservations as filesystem locks.

### Reuse existing work

| Existing work | Role |
|---|---|
| [#89](https://github.com/scgopi/GraphCode/issues/89) | Windows umbrella and short backlog index |
| [#551-#562](https://github.com/scgopi/GraphCode/issues?q=is%3Aissue+label%3Awindows) | Existing setup, startup/onboarding, packaging, and validation findings; the query also includes subsequently labeled work |
| [#438](https://github.com/scgopi/GraphCode/issues/438) | Bounded UIA polling |
| [#445](https://github.com/scgopi/GraphCode/issues/445) | Integrated post-merge Windows validation |
| [PR #547](https://github.com/scgopi/GraphCode/pull/547) | Existing navigation/rename work; refresh its state before overlapping changes |
| [#564](https://github.com/scgopi/GraphCode/issues/564) | Staged App decomposition, assigned to coneilen with the windows label at this snapshot |

Refresh the umbrella's historical integration instructions against the agreed
current repository workflow before dispatching tasks. Do not invent a parallel
cherry-pick or integration-branch policy.

## 2. Make autonomous claims atomic across all PCs

One engineer remains accountable for each execution issue. Record the execution
separately: PC alias, persistent coordinator identity, worker/session,
branch/PR, and declared edit scopes.

**GitHub assignees, labels, and comments are not atomic locks.** They remain
the visible status, but a worker may start only after a global claim succeeds.
Two PCs using the same GitHub account are still different executions.

### Minimum claim helper

Propose a small repository helper, such as `Tools\windows\work.ps1`, for claim,
state update, and release operations. Keep selection and reasoning in the
coordinator; the helper enforces ownership and scope conflicts.

Store active claim records in one small JSON file on a dedicated coordination
branch, outside the source/release branches. Use the GitHub Contents API's
expected file SHA for conditional updates. On a conflict, reread and reevaluate
with bounded backoff; do not overwrite another coordinator's state.
Verify these conditional-write semantics in a real concurrent test before
enabling unattended work. If the backend cannot confirm atomic acquisition,
do not substitute read-then-assign behavior and call it safe.

Reuse fetched state and honor GitHub rate-limit/backoff headers. Coordinators
using the same user credentials share the relevant API budget; do not hard-code
a per-PC allowance or multiply retries under contention. Use returned limits
and reset times, following the
[GitHub rate-limit guidance](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).
No separate rate-budget service is needed.

Acquire an issue and its exclusive edit scopes in the same update. Each claim
has a unique ID, owner/execution identity, state, branch/session, and PR once
available. Readiness and task metadata stay on the issue; the registry stores
active ownership, not a second backlog.

After successful acquisition, recheck the issue is still eligible, mirror
ownership into its assignee/comment, and launch the worker. If mirroring or
launch fails, retain a recoverable claimed state rather than silently starting
unrecorded work. A lost API response is reconciled using the persisted claim ID;
it is not permission to create another claim or worker.

If the eligibility recheck fails before launch, release the unused claim and
reselect. Temporary occupancy of an edit scope makes a task unsuitable for this
selection attempt; it does not justify permanently labeling the issue blocked.

Only the matching claim owner can change its work state or explicitly hand it
off. Scope expansion also needs a conditional update before editing additional
shared areas. A worker checks ownership at mutation boundaries; loss of access
or ownership pauses new mutations and preserves work.

This is cooperative execution control, not a security boundary. One-time
setup must authorize participating accounts and the coordination branch.
Preserve applicable commit/sign-off rules, store no secrets, and use no
force pushes or silent fallback on permission/network errors.

### Keep recovery simple initially

Claims persist through review until merge or explicit release. No automatic
expiry, heartbeat protocol, or time-based takeover is required in the first
version. This defers cross-PC takeover, not supervision of the coordinator's
own workers. A stopped PC cannot lose its branch because it has been quiet.

On restart, a coordinator reconciles its existing claims, sessions, and PRs
before selecting new work. A takeover of unfinished work requires a confirmed
handoff or engineer decision; do not infer failure from silence. This is the
deliberate tradeoff that keeps recovery safe and the helper small.

Monitor local worker/session and owned-command status. An explicit exit or
failure, or an exceeded configured stage deadline, triggers local recovery.
An unchanged branch or quiet log alone is not proof of a hang. Confirm the
worker stopped before any retry; preserve its work and claim in a
`needs-attention` state if recovery is uncertain.

Stopped workers do not consume running-worker capacity, but their unresolved
claims still count toward the in-flight ceiling and retain exclusive scopes.
Other independent work can use spare capacity. If retained claims exhaust that
ceiling, report the attention request rather than silently stalling or creating
an unbounded pile of new tasks. This needs no cross-PC heartbeat protocol.

Any coordinator may idempotently retire a claim whose recorded PR is confirmed
merged and whose bounded task is complete. It must not take over live work.
Changing ownership invalidates the old claim ID for further updates.

Before retiring a completed claim, leave a durable completion comment on the
issue with the claim ID, PR/target/merge commit, and acceptance/evidence links.
Verify the underlying GitHub outcome, not just the comment. Keep the comment
idempotent so retries do not duplicate it. Dependencies must remain verifiable
after the active claim is removed.

## 3. Open up App boundaries incrementally

The inspected `App.zig` has 12,779 lines and 110 top-level tests. Use the
existing [refactoring issue](https://github.com/scgopi/GraphCode/issues/564)
to track a staged, behavior-preserving split, not a global prerequisite.

Prepare only the next useful bounded extraction tasks for dispatch. Graph
commands and worktree coordination are the initial candidates; accessibility,
workspace lifecycle, updates, and navigation follow when needed. Keep one
integration owner and the `app-integration` scope for overlapping App changes.
An approved engineer restriction can be recorded in the issue body without
building a separate permission system.

Move state ownership and tests with behavior, reuse existing domain helpers,
and keep App as the composition root. Preserve UI-thread affinity, modal
revalidation, identities, callback lifetimes, and cancellation/join ordering.
Register moved/new test coverage with the existing Windows runner.

Do not combine extraction with unrelated fixes or reserve App until the whole
tracking issue closes. Downstream work depends on its specific landed boundary;
independent startup/provider/setup work can proceed now. Other contended files
such as `NativeForms.zig`, `GraphModel.zig`, and the UIA gate use the same scope
mechanism. Success is useful work unlocked, not a target line count.

## 4. Start once and let each coordinator select work

The engineer supplies one-time operating policy, not issue numbers:

- Allowed repository/backlog and authenticated engineer identity.
- PC alias and verified capabilities, including its authorized live-test profile.
- Running-worker capacity and a bounded in-flight task ceiling.
- Preview-first priority and whether parity work may fill otherwise idle slots.
- Merge policy and operations requiring separate approval.

Each PC has one active local coordinator identity, persisted across restarts.
Prevent accidental duplicate coordinators on the same PC. Different engineers
and PCs consume the same ready backlog through the global claim helper.
They do not need preallocated issue lists.

| Concern | Rule |
|---|---|
| Engineer ownership | One engineer may own several independent tasks across PCs |
| Execution ownership | One active claim per task, with a PC alias and coordinator/worker identity |
| Code overlap | Acquire conflicting edit scopes globally; separate PCs do not remove code conflicts |
| Working directories | Separate task-owned worktrees, writable providers, builds, caches, and runtime fixtures |
| Live tests | One enforced local runner per affected test environment; independent PCs can test concurrently |
| Evidence | Identify source/artifact hashes and the actual OS/display/backend profile |

### Selection and execution loop

1. Reconcile existing claims, worker/session state, and recorded PRs.
2. Discover open `windows-ready` issues, with complete pagination. Exclude
   blocked issues, unmet dependencies, incompatible capabilities, active manual
   work/PRs, and tasks restricted to another engineer.
3. Rank preview blockers and useful prerequisite/enabler work first; then use
   priority and age to choose between suitable tasks. Parity can fill slots
   when no suitable preview task is available and the operating policy permits.
4. Atomically claim the best available task and its edit scopes. If another
   coordinator wins, reread the queue and try another suitable issue.
5. Fetch the intended target branch, start from its current commit, and create
   a dedicated task worktree/session. Include the claim ID and bounded scope
   in the worker kickoff. Do not implement in the coordinator's checkout.
6. Fill available running-worker capacity without exceeding the in-flight
   ceiling. Tasks must have independent edit scopes; local builds and live
   tests obey the PC's resource limits.
7. Follow each task through validation, PR creation, review changes, checks,
   and authorized merge. Keep follow-ups in the same task execution.
8. Confirm merge and bounded acceptance, retire the claim/scopes, refresh the
   target branch, and select the next suitable issue for the freed slot.

Waiting-for-review and needs-attention claims count toward the in-flight ceiling
but need not occupy a running worker. This separates compute capacity from
bounded unfinished work. Other task slots continue; one pending PR must not
stall the whole coordinator. Helpers may read/test, but multiple writers must
not share a task worktree.

If the queue has no eligible work, report why and wait for a scheduled wake or
relevant GitHub/session event. Use a persistent coordinator session and an
existing same-session wake mechanism or local supervisor; do not spin an LLM
poll loop or repeatedly create fresh coordinators. Recheck the queue on wake.
Missing toolchains, permissions, test profiles, or genuinely exhausted work
are explicit states, not successful execution.

Agents are started locally unless an authorized remote-execution capability is
actually configured. An agent on PC-A cannot assume it can launch or stop agents
on PC-B. Use GitHub for cross-PC visibility; never put credentials, private
machine details, or sensitive runtime data in ownership comments.

### Example coordinator instruction

> Run the Windows backlog coordinator on PC-B for scgopi/GraphCode, using my
> authenticated account and the verified capabilities of this PC. Allow up to
> two running implementation workers and four in-flight tasks. Prefer preview
> blockers and their enablers; allow ready parity work when no suitable preview
> task is available.
>
> Select issues yourself from the ready backlog. Use the atomic claim helper
> before spawning workers, and enforce local live-test exclusion. Give each
> worker a bounded issue, claim ID, declared scope, dedicated worktree, and
> repository instructions.
>
> Carry tasks through tests, PR creation, CI, and review follow-ups. Observe
> authorized merges; do not assume permission to approve or merge PRs. Once a
> task has merged and met its acceptance criteria, release it and take the next
> eligible task. Keep other independent task slots progressing meanwhile.
>
> Recover existing tasks on restart. If idle, wait and recheck rather than
> inventing work. Report exceptions; do not force ownership, bypass checks,
> change pins, alter an existing installation, or perform machine-wide changes
> without authorization.

These are example limits, not universal capacity claims. Start with conservative
defaults and tune to compute, reviewer throughput, and test environments.

### PR lifecycle and merge authority

Default to observing maintainer merges. Autonomous task selection does not
grant merge or review-approval authority. With separately granted merge
permission, use normal repository rules/auto-merge only after the applicable
reviews and required checks pass; never use an administrative bypass.

Before retiring a task, verify the recorded PR is actually merged into its
intended target and that it covers the task's acceptance. A PR closed without
merge, an unrelated merge, an issue closed without evidence, or partial work
does not release the task as successfully completed.

CI or review failures remain with the existing worker. Explicit blockers get a
recorded reason and safe handoff/release decision, not repeated failing launches.
Claims with unresolved work are preserved while other eligible tasks progress.

### Handoff between PCs

The old execution stops new work and posts the branch/PR, current state,
unfinished changes, relevant evidence, and next action. Preserve uncommitted
work through an agreed transfer; do not assume it exists on the receiving PC or
discard it.

The receiver confirms the handoff and conditionally transfers the claim before
continuing. Do not run competing implementations or casually switch a branch in
a checkout shared by active sessions. Never respawn a worker merely because
the original launch response timed out; first reconcile the existing execution.

## 5. Give live tests a designated runner

Builds and non-interactive tests can run in parallel when their writable
resources are isolated. Foreground input, clipboard, tray/Explorer, capture,
scheduled tasks, and installation tests affect shared environments.

For each affected environment, the local coordinator queues live tests through
one runner with an OS-backed exclusion mechanism at the test entry points.
This must cover other coordinators/processes in the same affected environment,
not merely workers inside one agent conversation. Pure work can continue while
live tests wait. A small wrapper and local queue are sufficient; no scheduling
service is needed.

Independent PCs provide additional live-test capacity. Multiple sessions on the
same PC may still share account or machine installation state; do not assume
desktop separation isolates those effects.

The existing `ForegroundLease` string is not enforced mutual exclusion.
Enforced local exclusion is now part of the unattended-coordinator minimum,
not something to defer until another desktop collision. No automatic
environment provisioning or remote-PC control is assumed.

Use task-owned temporary/configuration/build directories and pinned toolchains.
Do not redirect `USERPROFILE` as a runtime-isolation workaround: the daemon
crash is tracked separately. `GRAPHCODE_SUPPORT_DIR` is the current runtime
override, but the onboarding marker and validation profile leaks remain known
gaps. Do not claim complete isolation until the exact path is verified; defer
tests that would touch an existing installation or profile without approval.

After an interrupted live run, confirm the owned processes and fixtures before
reusing the environment. Never stop unrelated processes, bypass security
controls, or install/register startup tasks without authorization.

Declare live-test eligibility as a verified capability. A coordinator on a PC
without an authorized test profile chooses other suitable issues; it must not
claim native qualification and replace the required observation with a stub.

## 6. Prioritize the preview without abandoning parity

Start independent work immediately; increase domain parallelism as App
boundaries land. Keep deferred parity work in the backlog and let it proceed
where it does not occupy the preview's contested integration/test capacity.

| Workstream | First useful outcome |
|---|---|
| Startup/onboarding | Fresh-directory daemon launch, reachable onboarding, connected Welcome, and isolated seen state |
| Terminal/provider | One real agent backend with readable output, exact input, working resize, and session continuity |
| Production forms/navigation | Correct project identity, create/rename/edit/cancel behavior, and reload persistence |
| Qualification reliability | Bounded, diagnostic, isolated runs and integrated post-merge validation |
| Packaging/recovery | Verified candidate install, manual upgrade/rollback/uninstall, and preserved fixture data |
| Contributor setup | Reliable pinned bootstrap followed by usable build/run guidance |
| Remaining parity | Remote flows, richer topology, complete accessibility/updater behavior, wider hardware/input support, and matched visual evidence |

Investigate failures rather than automatically classifying them as product bugs
or flakes. Setup improvements accelerate contributors but should not become
unnecessary prerequisites for testing a prebuilt preview.

The seven preview gates remain:

1. Exact artifact and provenance.
2. Clean installation and recovery.
3. Production core flow.
4. Useful real-agent terminal.
5. Reachability and lifecycle.
6. Safe mutations.
7. Honest tester handoff.

Use the source plan for their detailed acceptance conditions. The final
qualification identifies the exact candidate and declared support profile;
observations from different source revisions or packages are not interchangeable.
Relevant changes require reassessment of affected evidence.

## 7. Integrate with the existing quality rules

Each implementation PR is scoped, DCO-signed, and reviewed with the repository
template, observed RED/GREEN/REGRESSION evidence, positive executed counts, and
required checks. Use focused local validation and the existing sharded CI;
reuse the post-merge validation work rather than introducing another suite.

Preserve failing output. Distinguish pure, hidden-window, stub-backed, production,
foreground-input, and physical-hardware evidence. Shared Swift changes need
Windows and macOS regression ownership; provider changes and repins require
separate validation and approval.

A merged fix may close its bounded implementation issue. It does not
automatically qualify a preview gate or mark a whole parity row Validated.
Update the ledger explicitly when the necessary behavior and runtime evidence
are accepted. Publication remains a separate maintainer decision.

Keep the seven-gate checklist and the parity ledger as separate progress views.
Measure useful qualified behavior and reduced coordination friction, not just
numbers of issues, agents, PRs, or passing unit tests.

## Minimum tooling and proof before unattended dispatch

Build one small coordination helper plus local runner exclusion, and connect
them to the existing agent/session/worktree facilities. No new web service,
Project database, issue importer, or remote execution platform is required.

Verify the exact autonomous behavior before enabling it:

- Two PCs racing for one issue produce exactly one successful claim/worker.
- Different issues with overlapping edit scopes cannot both acquire them.
- Manual claim requests obey the same contended-scope exclusion.
- Independent suitable issues can launch multiple workers within configured
  limits, while local live tests remain exclusive.
- Wrong capabilities, unmet dependencies, and missing metadata prevent dispatch.
- Closed-but-unmerged dependencies remain unmet; completion is still verifiable
  after the active claim is retired.
- Failed post-claim eligibility checks release only unused claims.
- Lost claim/launch responses and coordinator restart do not duplicate workers.
- A stopped/failed local worker frees running capacity without losing its
  claim/work; suspected hangs are not duplicated or misread from silence.
- A PR awaiting review leaves other task slots active; closed-unmerged PRs are
  not counted as completion.
- An authorized merge releases the completed task, refreshes the target, and
  leads to selection of the next eligible issue without engineer task-picking.
- Idle coordinators wake and resume when work becomes eligible; backend errors
  fail explicitly, and stale claims do not trigger automatic takeovers.
- Same-account coordinators respect the shared API limits and back off without
  multiplying retries.

Keep test counts and retained failure evidence. Passing an isolated claim test
does not establish the whole coordinator lifecycle or production app behavior.

## Initial rollout

Run two preparation tracks in parallel:

- **Coordination:** build the small helper first and test same-issue races,
  overlapping scopes, and disjoint claims. Add local exclusion, reconciliation,
  and the complete task-to-merge-to-next-task loop.
- **Backlog:** inventory/deduplicate all outstanding requirements while preparing
  a small seed batch of independent preview/enabler tasks and a suitable parity
  task. Agree readiness, scope, and merge policy; make only bounded tasks ready.

Then pilot two coordinators on two PCs, including the same-account case, against
that seed batch and the proof checklist. Full-backlog coverage remains required,
but completing it is not a prerequisite for the pilot.

After the pilot passes, start additional coordinators with operating policy
only, continue backlog preparation, and let them select useful App stages and
independent work. Qualify the integrated preview against the seven gates while
continuing suitable full-parity work.

No engineer needs to select individual issues or manually refill a PC's queue.
Exceptional permissions, unsafe operations, and unfinished-work takeovers still
require explicit decisions.

## Defer tooling beyond the autonomous minimum

| Observed problem | Smallest next response |
|---|---|
| Issue list becomes hard to navigate | Add a simple Project board |
| Repeated requirement/issue drift | Add a narrow coverage check before considering synchronization tooling |
| App or another shared file still blocks useful PRs | Prioritize the next responsibility boundary or agree a smaller integration seam |
| Persistent abandoned claims require too much intervention | Design additional liveness/recovery controls with evidence-preservation safeguards |

The small claim registry and local exclusion are justified by autonomous
selection, not by a desire to build a platform. Continue to defer expiring
leases, heartbeat protocols, a general resource scheduler, automatic VM
provisioning, issue importers, and multi-field dashboards until a demonstrated
problem cannot be solved with a smaller mechanism.
