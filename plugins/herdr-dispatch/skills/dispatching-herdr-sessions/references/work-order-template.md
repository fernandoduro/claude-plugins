# Work-Order Template

A work order is the entire context its session gets. Write it so a fresh Claude in an unfamiliar
cwd can finish the item without asking you anything.

## Template

```
Task: <verb> <item> (<item title>).

Repo: <owner/repo> · branch <branch>
Isolated checkout: <one of the two forms below>

<Context — the facts you verified, file:line, reviewer, symptom. Nothing speculative.>

<Workflow — the named skills in order, with the condition that selects them.>

<Constraints — guard blocks from the library below.>

<Finish line + report-back contract.>
```

### The two Workplace forms

**A checkout already exists and is current** (found with `git -C <repo> worktree list`):

```
Isolated checkout (already exists, you are in it): /abs/path/to/worktree
```

**It exists but is behind the item's live head:**

```
Isolated checkout (already exists, you are in it): /abs/path/to/worktree
Its HEAD (<short-sha>) is behind the PR's current head (<short-sha>). Fetch and fast-forward to
origin/<branch> before you start, so you work against what is actually on the PR.
```

**None exists** — or the only one belongs to another automation (`~/.local/state/<tool>/worktrees/…`,
an agent runner's workspace tree), which may reclaim it mid-session. Either way the session starts in the
component checkout and must isolate itself first:

```
Isolated checkout: NONE EXISTS YET. You are starting in the main <component> checkout — do not
switch its branch. Before touching any file, create your own worktree:
    git worktree add ../wt-<branch-slug> <branch>
(or the repo's own worktree helper) and work there.
```

## Guard library

Paste the blocks that apply to the verb. Repo-agnostic phrasing; swap tool names per project.

### Parallel-session guards (any repo with concurrent sessions)

```
Parallel-session guards (many Claude sessions run on this repo at once):
- Work ONLY in the isolated checkout named above. Never switch branches inside a main checkout.
- Never stop, restart or rebuild another clone's containers, workers or queues — another session may own them.
- Never bind-mount a main checkout as a container root (Docker leaves root-owned 0-byte stubs behind).
- Any counts or states quoted above are a snapshot from <date>. Re-check live state before acting.
```

### Outward-action stops (PR/issue work)

```
Hard stops — do NOT, under any circumstances:
- merge this PR. It still needs a human review pass, even where an older approval is showing.
- approve any review, or close the PR/issue.
- push to master, force-push anything, or rewrite/collapse commit history — keep the full history.
- request or re-request review from a teammate — surface that as a recommendation instead.
```

Drop or extend per verb: an *investigate* item adds "change no code, write findings only"; an
*implement* item drops the review lines but keeps the history and isolation ones.

### Where the workflow's side effects begin

Name the gate, don't assume the invoked skill will hold at it. A review workflow that normally
asks a human before publishing has no human in an unattended pane:

```
Workflow: invoke /review-pr on PR #<n>. It reaches a publish step — that is your full stop.
Report the findings in this pane and publish nothing: no review, no comment, no approval.
```

### Finish line + report contract

```
Finish line: <the item's definition of done>. Then STOP and report in this pane: <the 3-4 facts
the user needs>, and anything needing <user>'s decision. Do not move on to another item.
```

### Project-specific extras

- **Sites behind a shell wrapper** (LocalWP and similar): `wp`/`php`/`composer`/`mysql` only work
  through the site's wrapper script — name it in the work order.
- **Components with their own containers**: give the session a dedicated clone, not a worktree,
  when it must run containers or queues; a fresh worktree also needs the gitignored env files
  copied in (copy, never symlink — a symlink shares state with the source checkout).
- **Tests-with-logic rule**: if the project requires a pinning test in the same commit, say so
  in the work order — "write it failing first and confirm it can fail".

## Hook note — phrasing prohibitions

Guard hooks pattern-match the literal text of your Bash calls, including heredocs that only
*quote* a forbidden command to ban it. Writing a work order that spells out banned git
subcommands gets the whole write blocked.

Describe the prohibition instead of quoting the command:

- ✅ "rewrite or collapse commit history — keep the full history"
- ❌ spelling out the interactive-rebase / squash-merge / fixup invocations

Same shape applies to the `#1 #2 #3` ordinal guard (GitHub autolinks those to issues — use
`1.` / `2.`) and the third-party-upload guard.

## Worked example

```
Task: address the 2 unresolved review threads on acme/checkout-api PR #118
(feat(tracing): trace which code writes a completed order status).

Repo: acme/checkout-api · branch feat/118-status-write-trace
Isolated checkout: NONE EXISTS YET. You are starting in the main checkout — do not switch its
branch. Create your own worktree before editing:
    git worktree add ../wt-118-status-write-trace feat/118-status-write-trace
and work there.

Both threads are from @jdoe on src/Tracing/StatusWriteTrace.php. The dashboard row names a
different reviewer — @jdoe is who actually commented:
1. line ~380 — attribute() returns on the first frame that is not this tracer, the DB adapter, or
   the framework bootstrap, so a write routed through a framework API is attributed to the
   framework instead of the real caller.
2. line ~305 — the statement-type guard accepts only UPDATE and INSERT, so the adapter's
   REPLACE INTO path — a plausible shape for the very write being hunted — reads as
   "no bypass found".

Both are correctness gaps in the tracer's core promise, so treat them as real unless the code
proves otherwise. Run the repo's finding-triage skill if you disagree with either, then its
feedback-addressing skill to fix, reply and resolve.

The dashboard's stated next step is "re-request review". Do NOT do that — report when the threads
are settled and let the requester decide.

<parallel-session guards>
<outward-action stops>

Finish line: every unresolved thread either has a reply and is resolved, or is listed in your
report with the reason it stays open. Then STOP and report in this pane: per-thread verdict, what
you changed, what you pushed, anything needing the requester's decision. Do not move on to
another PR.
```

Why this one works: the verb is unambiguous, both findings are stated as verified facts with
file:line, the dashboard's reviewer error is corrected rather than propagated, the workflow is
conditional (triage only on disagreement), and the one action the dashboard suggested but the
requester never authorized is explicitly withheld.
