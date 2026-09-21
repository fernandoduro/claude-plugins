# cmux-cli skill refresh — cmux 0.64.25

Skill was written against ~0.64.20–22. Three things it states are now false, one
whole subsystem exists that makes ~150 lines of the skill's forensics obsolete,
and the CLI has begun a noun migration the skill teaches nothing about.

Evidence below is all from live probes on `cmux 0.64.25 (106)`, not from docs.

## 1. Stale facts — actively misleading, fix first

| Skill says | Actually |
|---|---|
| "`--json` is per-command, not global … `list-workspaces --json` silently ignores the flag and prints text" | `cmux list-workspaces --json` **returns JSON**, and `cmux --json <cmd>` works as a global prefix (`cmux --json top --all` is in cmux's own help). The whole "prefer `tree`/`identify` for JSON" workaround is now unnecessary. |
| `CMUX_SOCKET_PATH` default = `~/Library/Application Support/cmux/cmux.sock` | `~/.local/state/cmux/cmux.sock` (per `cmux --help`), with auto-discovery of tagged/debug sockets. |
| Misc list names `claude-hook` as the integration verb | `claude-hook` still works, but there is now a `cmux hooks` subsystem (`hooks setup`, `hooks <agent> install`, 17 agents). Claude Code hooks are injected automatically by cmux's claude wrapper. |

Also new and unmentioned: **`CMUX_QUIET=1`** silences the legacy-alias deprecation
notices. Those notices go to **stderr**, so pipes and `jq` are unaffected — worth
stating explicitly so nobody "fixes" a non-problem.

## 2. `cmux events` — the headline

A retained, replayable, filterable NDJSON event stream. Nothing in this repo uses
it. It answers, authoritatively and with zero polling, the exact questions the
skill currently answers with `read-screen` forensics.

```
cmux events [--after <seq>] [--cursor-file <path>] [--name <event>]
            [--category <cat>] [--reconnect] [--limit <n>]
            [--timeout <seconds>] [--snapshot] [--no-ack] [--no-heartbeat]
```

Harvested catalog (530 retained events, live):

| category | names |
|---|---|
| `agent` | `hook.SessionStart`, `hook.UserPromptSubmit`, `hook.PreToolUse`, `hook.Stop`, `hook.SubagentStop`, `hook.SessionEnd`, `notification.decision`, `journal.unattributed` |
| `surface` | `created`, `selected`, `focused`, `closed` |
| `workspace` | `created`, `selected`, `closed`, `reordered`, `prompt.submitted` |
| `pane` | `created`, `focused` |
| `window` | `created`, `keyed`, `unkeyed` |
| `notification` | `created`, `read`, `cleared`, `clear_requested`, `removed` |
| `feed` | `item.received`, `item.completed` |
| `sidebar` | `metadata.updated` |

Every frame carries `seq`, `occurred_at`, `category`, `name`, and top-level
`surface_id` / `workspace_id` / `pane_id` / `window_id`, so filtering to one
target is a `jq` select, not a heuristic.

### What this replaces

**(a) "Did my message actually submit into that claude REPL?"** — today: ~150
lines of input-box forensics (NO-BREAK SPACE discriminator, spinner elapsed-time
parenthetical, `Press up to edit queued messages`, nonce-in-transcript checks for
the confirmed fragmentation and silent-byte-loss failures).

`workspace.prompt.submitted` answers it directly. Payload carries
`message_length` and a 240-char `message_preview` (with `message` itself in
`redacted_fields`):

```json
{"name":"workspace.prompt.submitted","seq":221,
 "payload":{"message_length":240,"message_preview":"<task-notification> …",
            "redacted_fields":["message"],"workspace_id":"36CB…"}}
```

So: send, then wait for the event; compare `message_length` against the bytes you
sent to **detect the silent-byte-loss case**, and count events to detect the
**fragmentation** case. That is a measurement where the skill currently has a
nonce convention and a warning. `agent.hook.UserPromptSubmit` corroborates it
per-surface with `session_id`, `surface_id` and `cwd`.

**(b) "Is the new surface ready?"** — `surface.created` carries
`{surface_id, pane_id, kind, origin, focused}`. Keeps the PTY-attach probe
(a send is still what attaches the PTY) but removes the guesswork about
whether the surface exists yet.

**(c) "Is the other agent done?"** — `agent.hook.Stop` / `SubagentStop` /
`SessionEnd`, filtered to a `surface_id`:

```bash
cmux events --category agent --name agent.hook.Stop \
            --limit 1 --timeout 600 --no-heartbeat 2>/dev/null \
  | jq -e --arg s "$SURF_ID" 'select(.surface_id==$s)'
```

One blocking call, no wake-ups. This is the zero-token primitive
`maestro:patient-waiting` describes and `references/progress-loops.md` currently
hand-rolls with `pgrep` + periodic `set-progress` writes.

**Two traps to document:** `--timeout` exits non-zero with a plain-text
`Error: Timed out waiting for a matching event` — keep stderr out of the stream
you feed to `jq` (this bit me while harvesting). And `--after 0` replays the
retained buffer, so "did it submit?" is answerable *after the fact*, not only by
subscribing first.

## 3. The noun migration

`cmux workspace` and `cmux surface` are now canonical nouns; the legacy verbs are
aliases that print a one-time deprecation hint to stderr. The skill teaches
legacy forms exclusively.

- `cmux workspace <list|create|env|close|rename|select|status|reconnect|disconnect|loading|group>`
  — `list-workspaces`, `new-workspace`, `close-workspace`, `rename-workspace`,
  `select-workspace` all now hint here. New capability worth naming: `workspace env`
  (configured env vars, `--mask`), `workspace reconnect|disconnect` for remote SSH
  workspaces (a real gap — `references/ssh.md` covers reconnect by hand).
- `cmux surface <ls|open|new-terminal|resume>` — the skill only knows
  `surface resume`. `surface ls/open/new-terminal` is a **resource catalog**
  (`<machine>/<kind>/<key>`), and `surface open` *reuses the pane already showing
  a resource* unless `--new`, with `--pane <p> --right|--tab` for placement.
- No `window`/`pane`/`tab` nouns yet — checked, they error.

Teach canonical, keep legacy in a one-line "these still work" note.

## 4. Subsystems the skill omits entirely

Ranked by value to how JT actually uses cmux.

1. **`cmux diff`** — `--unstaged|--staged|--branch|--last-turn` renders a diff in
   a browser split. `--last-turn` is "changes since this surface's last agent-turn
   baseline": a one-call way to show the user what you just did. Pairs with
   `markdown` under the existing visibility principle.
2. **`cmux todo`** — per-workspace sidebar checklist. cmux's own help says: *"this
   checklist belongs to the user. Do not add, edit, complete, remove, or replace
   items on your own initiative — only manage it when the user explicitly asks."*
   Encode that as a prohibition, with `todo.v1` in `capabilities`.
3. **`cmux vault`** — `sessions` / `search <query>` (supports `agent:`, `repo:`,
   `ws:`, `before:`/`after:` operators) / `checkpoints` / `checkpoint` / `fork`
   over indexed agent sessions. Overlaps `graveyard` and `session-tools`; worth a
   pointer both ways.
4. **`cmux top` / `cmux memory`** — CPU/RAM by window/workspace/pane/surface,
   `--format tsv`, `--processes`. The right first move on "cmux is hot / which
   pane is spinning", which the skill has no answer for today.
5. **`new-surface --type agent-session --provider claude|codex|opencode`** — a
   native agent surface. hotline hand-rolls this by sending a launch line into a
   terminal surface; worth at least naming.

Smaller, one-line-each: `restore`/`fork` checkpoints, `sessions list`,
`comments list`, `automation`, `themes`, `right-sidebar`/`sidebar`, `feed`,
`sudo run` (Touch ID), `remotes`, `popup`, `local-tmux`/`mosh`/`ssh-tmux`,
`move-tab-to-new-workspace`, `workspace create --group/--group-placement`,
`reorder-workspaces`, `identify --no-caller`.

Browser reference needs a pass for verbs it predates: `react-grab`, `devtools`,
`focus-mode`, `design-mode`, `zoom`, `history clear`, `profiles`, `import`,
`download`, `state save|load`, `addinitscript`, `focus-webview`.

## 5. Deliberately out of scope

- **`cmux vm` / `cloud` / `agent`** (cloud machines, cloud coding agents). Large
  subsystem, but `cmux cloud ls` on this machine returns
  `cloud_disabled: Cloud Machines are temporarily unavailable` — can't verify a
  single claim about it. One line pointing at `cmux cloud guide` (which is cmux's
  own live agent doc) instead of a reference file written from help text.
- **`simulator` / `ios`**, `coderouter`, `ai-accounts`, `iroh-diag` — not in play.
- **Rewriting `open-side-surface.sh` around `surface open`** — `surface open`
  plausibly subsumes its 503-line decision tree, but it is load-bearing for
  hotline and has tests. Separate change, separate verification.

## 6. Edit plan

1. `SKILL.md` — fix the three stale facts; add a "waiting and verifying with
   `cmux events`" section that the send/read-screen gotchas then *defer to*
   (shrink the forensics to "fallback when events are unavailable", don't delete —
   they're still the only path outside cmux); teach canonical nouns; add `diff`,
   `todo` (prohibition), `top`/`memory` to the vocabulary and the NL-translation
   table; point at `cmux guide` / `cmux --skill` as the live index under the
   existing golden rule.
2. `references/progress-loops.md` — rewrite the primary recipe on `events`
   (`--name agent.hook.Stop --timeout`), demote the `pgrep` poll to the fallback.
3. `references/browser.md` — add the missing verbs.
4. `references/ssh.md` — add `workspace reconnect|disconnect`.
5. New `references/events.md` if §2 outgrows its section — catalog + payload
   shapes + the `jq` filters.
6. `README.md` + plugin `description` — mention events/waiting.
7. Tests: `plugins/cmux-cli/tests/` — an events-catalog probe would be
   machine-dependent; assert instead that the skill's documented event names are
   a subset of what `cmux events --snapshot`/replay reports, skipping when cmux
   is absent.
8. `bash tests/run-all.sh`, then `compounding-preflight`.

## 7. Open question

Does the events finding propagate to **hotline** in this change-set?
`plugins/hotline/skills/dial/scripts/` has `surface-ready.sh`,
`wait-for-session.sh`, `repl-state.sh` and `cmux-reuse-surface.sh` — all
read-screen polling and REPL-state heuristics that `surface.created`,
`agent.hook.SessionStart` and `workspace.prompt.submitted` answer directly. Doing
it is "fix the class, not the instance"; not doing it leaves hotline on the old
mechanism while the skill teaches the new one.
