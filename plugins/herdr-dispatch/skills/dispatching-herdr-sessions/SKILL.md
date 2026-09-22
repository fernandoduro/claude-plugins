---
name: dispatching-herdr-sessions
description: Use when the user hands over a batch of work items — a screenshot of a PR/issue table, a list of links, a numbered list — and wants each item handled by its own Claude session in its own Herdr tab. Triggers include "create a pane for each of these", "a tab per PR", "fan these out", "one session per item", "dispatch these to herdr". Requires HERDR_ENV=1.
---

# Dispatching Herdr Sessions

## Overview

One batch of items in, one Herdr tab per item out, each tab running its own Claude session
that carries a self-contained work order.

**Your job is writing the instructions. The items' work belongs to the items' sessions.**
The dispatch has failed the moment you start fixing, reviewing, or investigating an item
yourself — even when it looks faster to just do it.

## When to Use

- 2+ items that can each be worked independently
- The user points at a list, a table, a screenshot, or a set of links and asks for a pane/tab/session per entry
- Items may carry *different verbs*: review this PR, address its threads, investigate this error, run skill X on it, implement this issue

**Don't use when:**
- One item — just do it here
- The items must run in sequence, or fight over one checkout that can't be isolated
- The user wants one session repeating a task on a schedule — that's `/loop`

## Preflight

```bash
test "${HERDR_ENV:-}" = 1        # if this fails: say you are not inside Herdr, and stop
herdr --skill                    # the installed binary is the authority on syntax
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_PANE_ID"
```

A cwd with no Claude-trusted ancestor (`~/.claude.json` → `projects[dir].hasTrustDialogAccepted`)
makes the spawned `claude` stop on the folder-trust dialog instead of starting. Trust is inherited
from parent directories, so worktrees under an already-trusted repo root are fine; paths like
`/tmp` or `$HOME` are not. `dispatch.sh` checks this before it creates anything.

Items become **tabs in your own workspace** (`$HERDR_WORKSPACE_ID`) — one tab each, never
splits of one tab. Seven panes sharing a tab is ~30 columns apiece and Claude's TUI needs
real width. Your own pane keeps the focus; every tab is created `--no-focus`.

## Step 1 — Parse the items

Transcribe every row/link the user pointed at, then apply their filter verbatim ("only the
ones with threads", "skip the drafts").

**A screenshot is a claim, not data.** Every field that will enter a work order — repo, number,
reviewer, thread count, next step — gets confirmed against the source of truth (`gh`, an API,
the file) first. Report mismatches to the user in one line; digest tables go stale and name
the wrong reviewer.

## Step 2 — Lean recon per item

Gather exactly four things per item, and stop:

| What | How |
|---|---|
| **Live state** | One call — `gh pr view`, `gh issue view`, the URL. Confirm it exists and still needs the work |
| **Verb** | What the user asked *for this item*: review / address threads / investigate / run skill X / implement |
| **Workplace** | The isolated checkout for that branch if one exists, **and whether it is current** — compare its `git rev-parse HEAD` to the item's live head (`gh pr view <n> --json headRefOid`). A stale worktree gets a sync instruction; syncing is workplace setup, not the item's work, so it belongs in the work order's Workplace slot |
| **Workflow** | The skill or command the session should invoke (the repo's review skill, its finding-triage → feedback-addressing pair, its debug or work kickoff skill, …) **plus its side-effect posture**: where that workflow would post, publish, push, or open something, and where this session must stop instead. State it even when the workflow's own default is "ask first" — a session running unattended needs to know the gate is a full stop |

Reading the diff, pulling every comment body, or forming a view on the right fix is the
session's job, not yours. Only do a deep inventory when the user explicitly asks for one.

**A checkout another automation owns is not a workplace.** Worktrees under another tool's state
directory (`~/.local/state/<tool>/worktrees/…`, an agent runner's workspace tree) can be reset or
reclaimed mid-session. Treat those as "none exists" and have the session create its own.

**Agent names** are `[a-z][a-z0-9_-]{0,31}`, unique among live agents, and short enough to read in
a status table: `<repo-short><number>` (`api42`, `web118`) or `<verb><number>`
(`rev118`) when one item could carry two verbs.

## Step 3 — Compose one work order per item

Each work order fills these slots, in this order:

| Slot | Content |
|---|---|
| **Task** | One sentence: the verb + the item + its title |
| **Coordinates** | Repo, PR/issue number, branch |
| **Workplace** | The exact cwd it starts in, and whether it must create its own worktree before editing |
| **Context** | The specific facts you verified in Step 2 — file:line, reviewer, symptom. No speculation, no fix proposals |
| **Workflow** | The named skill(s) to invoke, in order, with the condition that selects them |
| **Constraints** | Isolation guards + the outward-action stops that apply to this verb |
| **Finish line** | What "done" is, and the report-back contract: report in this pane, then STOP |

Codex: the path below resolves under Claude Code; substitute the directory containing this
`SKILL.md`.

**Read `${CLAUDE_SKILL_DIR}/references/work-order-template.md`** for the full template, the guard
library, and the phrasings that trip guard hooks.

## Step 4 — Present the table, then WAIT

Print one row per item — item · tab label · agent name · cwd · verb · workflow — plus any
parse mismatch you found. Then **stop and wait for an explicit go-ahead.** Create nothing
yet. A mis-parsed screenshot caught here costs one line; caught after launch it costs seven
sessions doing the wrong work.

The gate is unconditional. "Create a pane for each of these" is the request, **not** the
go-ahead — the go-ahead is the answer to the table. An explicit-sounding ask, a small batch, or an
obvious-looking item is not consent to skip it. If the answer never comes, leave the batch
undispatched and say so; a dispatched session is expensive to recall.

## Step 5 — Launch

Write one prompt file per item, then a tab-separated manifest:

Codex: the token below resolves under Claude Code; substitute the directory containing this
`SKILL.md`.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/dispatch.sh" manifest.tsv --dry-run   # validate; create nothing
bash "$SKILL_DIR/scripts/dispatch.sh" manifest.tsv             # agent_name <TAB> tab_label <TAB> cwd <TAB> prompt_file
```

Per row it creates the tab in your workspace, starts `claude` in its root pane with
`--permission-mode bypassPermissions` (a session that stalls on a permission prompt is not
dispatched work), sends the work order, and prints pane and tab IDs plus the resulting state.

A row whose session blocks at startup is reported with the dialog text and **its prompt is held
back** — answer the dialog in that tab, then re-run the manifest with only that row. Other rows
still go out.

## Step 6 — Verify and report

```bash
herdr agent list
```

Every dispatched name must read `working`. Report the final table, the constraints you put on
all sessions, and anything you deliberately left out. Then stop — you are not their supervisor
unless the user asks for that.

## Reading results later

```bash
herdr agent list
herdr agent read <name> --source recent-unwrapped --lines 120
```

If a completed response won't come back, the pane is on the alternate screen: ask that session
to write its report to a file and read the file.

## Red Flags — STOP

| Red flag | Recovery |
|---|---|
| "I'll just fix this one, it's a two-line nit" | Stop editing, revert what you touched, put the fix in that item's work order instead |
| "Let me read the threads/diff first so the prompt is better" | Close the diff; the four recon facts are enough. State the item's location and let the session read it |
| Splitting one tab N ways | Close the extra panes and create one tab per item |
| Launching before the go-ahead | Close the tabs you created, present the table, wait |
| A work order with no Workplace slot | Add it before dispatching, or the sessions fight over one checkout |
| A screenshot's reviewer/next-step copied in unverified | Confirm it against the source of truth, and report the mismatch in the table |
| A session told to merge, approve, close, deploy, or ping a teammate that nobody authorized | Remove it from the order, and surface it as a recommendation in your report |

## Common Mistakes

| Mistake | Fix |
|---|---|
| Work order says "address the review feedback" | Name the file:line and reviewer you verified; vague orders make the session re-derive your recon |
| Every session gets the same generic prompt | The verb differs per item — a review, an implementation, and an investigation need different workflows and different finish lines |
| Session starts in a main checkout with no isolation instruction | Give it its worktree, or make "create one first" step zero |
| Orchestrator keeps polling the sessions | Report once and stop unless asked to supervise |
| Dispatching into `/tmp` or another untrusted path | The session never starts — it sits on the folder-trust dialog. Dry-run first; the warning names the row |
| Prompt text quotes a banned command to forbid it | Describe the prohibition; guard hooks match your literal text (see the template's hook note) |
