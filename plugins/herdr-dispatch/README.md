# herdr-dispatch

One batch of work items in, one [Herdr](https://herdr.dev) tab per item out — each tab running its
own Claude session that carries a self-contained work order.

## The problem it solves

You are handed a batch: a screenshot of a PR dashboard, a list of issue links, a numbered list of
things to chase. Working them one at a time in the current session serializes work that is
naturally parallel, and the obvious shortcut — "I'll just fix this one, it's small" — quietly turns
the orchestrating session into the worker for item 1 while items 2..N wait.

This skill keeps the orchestrator's job to *writing the instructions*: verify each item, resolve
where it should be worked, name the workflow that does it, then dispatch.

## What it does

1. **Preflight** — confirms it is inside Herdr, reads the current workspace, checks that each
   target directory has a Claude-trusted ancestor (an untrusted cwd makes the spawned session stop
   on the folder-trust dialog instead of starting).
2. **Parse** — transcribes the items and applies the user's filter. A screenshot is treated as a
   claim: every field that will enter a work order is confirmed against the source of truth first.
3. **Lean recon** — per item, exactly four facts: live state, the verb (review / address feedback /
   investigate / run skill X / implement), the workplace (an existing isolated checkout, whether it
   is current, or "create your own first"), and the workflow to invoke with its side-effect posture.
4. **Compose** — one work order per item, filling seven required slots.
5. **Gate** — prints the dispatch table and waits for an explicit go-ahead. Nothing is created yet.
6. **Launch** — `scripts/dispatch.sh` creates each tab, starts the agent, sends the order, reports
   pane/tab IDs and states.

## Usage

```
scripts/dispatch.sh manifest.tsv --dry-run   # validate; create nothing
scripts/dispatch.sh manifest.tsv             # agent_name <TAB> tab_label <TAB> cwd <TAB> prompt_file
```

Options: `--workspace <id>`, `--kind <agent-kind>`, `--permission-mode <mode>` (default
`bypassPermissions` — a session that stalls on a permission prompt is not dispatched work),
`--focus`.

The launcher validates agent-name syntax and uniqueness, existing cwds, non-empty prompt files,
live-name collisions, and folder trust before it creates anything. A row whose session blocks at
startup is reported with the dialog text and **its prompt is held back**, while the other rows
still go out.

## Files

| Path | Role |
|---|---|
| `skills/dispatching-herdr-sessions/SKILL.md` | The workflow, the red flags, the common mistakes |
| `skills/dispatching-herdr-sessions/references/work-order-template.md` | The seven slots, the guard library, a worked example |
| `skills/dispatching-herdr-sessions/scripts/dispatch.sh` | Manifest-driven launcher |

## Requires

- [Herdr](https://herdr.dev) — the skill refuses to run outside a Herdr-managed pane (`HERDR_ENV=1`)
- `jq`
