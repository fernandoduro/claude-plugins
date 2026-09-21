# `cmux events` — the event stream (wait and verify without polling)

`cmux events` streams newline-delimited JSON for everything happening inside
cmux: surfaces opening and closing, prompts being submitted, agent turns
starting and ending, notifications, sidebar writes. The buffer is **retained and
replayable**, so it answers questions about the past as well as the future.

Reach for it before any `read-screen` loop, any `pgrep` poll, and any
`ScheduleWakeup` heartbeat. One blocking call with `--timeout` replaces all
three, and unlike screen scraping it reports **facts about what cmux did**
rather than inferences from what a TUI happened to be drawing.

```
cmux events [--after <seq>] [--cursor-file <path>] [--name <event>]
            [--category <category>] [--reconnect] [--limit <n>]
            [--timeout <seconds>] [--snapshot] [--no-ack] [--no-heartbeat]
```

## The invocation contract

Verified on cmux 0.64.25:

| Behavior | Detail |
|---|---|
| Exit code | `0` when a matching frame arrived, `1` on `--timeout` expiry. |
| Timeout message | `Error: Timed out waiting for a matching event` on **stderr**. |
| Ack frame | Printed to **stdout** first (`"type":"ack"`) unless `--no-ack`. It has no `.name`, so it breaks a naive `jq` filter. |
| Heartbeats | Every 15s unless `--no-heartbeat`. |
| `--name` / `--category` | Filtered **server-side**, repeatable. |
| `--after <seq>` | Replays retained frames after that seq. `--after 0` replays everything retained. |
| `--cursor-file <path>` | Reads the start seq from the file, then writes the last seen seq back to it after each frame. |
| `--snapshot` | Prints the subscription ack and exits — use it to read `oldest_seq` / `latest_seq`. |

**Scripted use is always `--no-ack --no-heartbeat` with stderr kept out of the
pipe**, or `jq` chokes on the ack frame and on the timeout line:

```bash
cmux events --name surface.created --limit 1 --timeout 30 \
            --no-ack --no-heartbeat 2>/dev/null | jq -c .
```

## The catalog

Harvested live from replays on cmux 0.64.25. **The retained buffer is a rolling window**, so no single replay contains every name — `surface.input_sent` and `agent.hook.Notification` appear in one replay and are gone from the next taken minutes later. Treat a name's absence from a replay as "nothing did that recently", never as "this event does not exist". cmux may also add names; re-harvest with
`cmux events --after 0 --no-ack --no-heartbeat --limit 900 --timeout 10 2>/dev/null | jq -r '[.category,.name]|@tsv' | sort -u`.

| category | names |
|---|---|
| `agent` | `agent.hook.SessionStart`, `agent.hook.UserPromptSubmit`, `agent.hook.PreToolUse`, `agent.hook.Stop`, `agent.hook.SubagentStop`, `agent.hook.SessionEnd`, `agent.hook.Notification`, `agent.notification.decision`, `agent.journal.unattributed` |
| `surface` | `surface.created`, `surface.selected`, `surface.focused`, `surface.closed`, `surface.input_sent` |
| `workspace` | `workspace.created`, `workspace.selected`, `workspace.closed`, `workspace.reordered`, `workspace.prompt.submitted` |
| `pane` | `pane.created`, `pane.focused` |
| `window` | `window.created`, `window.keyed`, `window.unkeyed` |
| `notification` | `notification.created`, `notification.read`, `notification.cleared`, `notification.clear_requested`, `notification.removed` |
| `feed` | `feed.item.received`, `feed.item.completed` |
| `sidebar` | `sidebar.metadata.updated` |

## Frame shape and how to target one surface

Every frame carries `seq`, `occurred_at`, `category`, `name`, `source`, and
**top-level** `surface_id` / `workspace_id` / `pane_id` / `window_id` — always
UUIDs, never refs. Filter on those, not on anything inside `payload`.

```json
{"name":"surface.created","seq":5,"category":"surface",
 "occurred_at":"2026-09-21T16:38:12.256Z",
 "surface_id":"F41D2405-…","pane_id":"31266DD3-…","workspace_id":"DDDF12C7-…",
 "payload":{"kind":"terminal","origin":"workspace_initial","focused":true,
            "surface_id":"F41D2405-…","pane_id":"31266DD3-…"}}
```

Three traps, all verified:

- **`agent.hook.*` fires twice per occurrence** — once with
  `payload.phase == "received"`, once with `"completed"`. Deduplicate with
  `select(.payload.phase == "completed")` or you will count every turn twice.
- **`surface_id` can be `null`** on some `agent.hook.*` frames (the hook arrived
  without attribution). A `select(.surface_id == $s)` filter silently drops
  those, so fall back to `payload.workspace_id` or `payload.cwd` when a surface
  match comes up empty.
- **Sensitive text is redacted.** Frames list what was withheld in
  `payload.redacted_fields`, and hand you a length and a preview instead — which
  is exactly what the verification recipes below need.

## Recipe: did my message actually submit?

This replaces the input-box forensics in SKILL.md. `workspace.prompt.submitted`
fires when a prompt is submitted into an agent REPL and carries an **exact**
`message_length` plus a 240-character `message_preview`:

```json
{"name":"workspace.prompt.submitted","seq":647,
 "payload":{"message":null,"message_length":43,
            "message_preview":"> I'd say yes, but as a second pass\nagreed.",
            "redacted_fields":["message"],"workspace_id":"4C7FA894-…"}}
```

`message_length` was confirmed character-exact against the submitted text. That
makes the two confirmed `cmux send` failure modes **measurable** rather than
merely warned about:

- **Silent byte loss** → `message_length` is smaller than what you sent.
- **Fragmentation** → several `workspace.prompt.submitted` frames for one send.

```bash
MSG="…"; LEN=${#MSG}
SEQ=$(cmux events --snapshot 2>/dev/null | jq -r '.resume.latest_seq')

cmux send     --workspace "$WS" --surface "$SID" "$MSG"
sleep 0.2
cmux send-key --workspace "$WS" --surface "$SID" Enter

# Every submission since the send, for that workspace.
cmux events --after "$SEQ" --name workspace.prompt.submitted \
            --limit 5 --timeout 15 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg ws "$WS" --argjson len "$LEN" \
      'select(.workspace_id==$ws)
       | {seq, got:.payload.message_length, want:$len,
          ok:(.payload.message_length==$len)}'
```

No frame within the timeout means **nothing submitted** — the text is sitting in
the input box, and `send-key Enter` is the fix (never a re-`send`, which appends).
One frame with a matching length is a clean submit. Anything else is the lossy
path, and the nonce-and-verify discipline in SKILL.md still applies.

`agent.hook.UserPromptSubmit` corroborates per-surface with `session_id`,
`surface_id` and `cwd`, but **do not length-check against it** — its
`tool_input_length` counts claude's wrapping (56 where `message_length` was 43),
not your payload.

## Recipe: did my `send` reach the surface I meant?

`surface.input_sent` fires on **every** `cmux send` — shell targets included, not
just agent REPLs — and it is the only event that reports **which surface cmux
actually resolved**:

```json
{"name":"surface.input_sent","seq":1195,"source":"socket.v2",
 "surface_id":"395ECEAE-…","workspace_id":"4C7FA894-…",
 "payload":{"method":"surface.send_text",
            "params":{"text":null,"text_length":25,"redacted_fields":["text"],
                      "workspace_id":"4C7FA894-…"},
            "result":{"queued":false,
                      "surface_id":"395ECEAE-…","surface_ref":"surface:20",
                      "workspace_id":"4C7FA894-…","window_id":"AD03B5BA-…"}}}
```

Two fields earn their keep:

- **`params.text_length`** — the exact byte count cmux delivered (25 for
  `"echo events-probe-marker\n"`). Compare against what you sent to catch
  truncation at the transport, one layer below the REPL.
- **`result.surface_id`** — the surface cmux resolved your handle to. Compare it
  against the surface you *intended*, because a handle that fails to resolve
  does not error; it falls back to the caller (see the trap below).

`result.queued` tells you whether the input was queued rather than delivered
straight through.

### Trap: an empty or unresolved handle silently targets *you*

`cmux send --surface "" …` does not fail. The empty value falls through to
`$CMUX_SURFACE_ID`, so the payload is delivered to **the caller's own surface**.
When the caller is an agent running inside a Claude Code REPL, that means the
text lands in the **user's input box**.

This is not hypothetical — it happened while writing this reference. A helper
script exited non-zero with empty stdout, `SID=$(jq -r '.surface_id' <<<"$OUT")`
produced an empty string, and the next `cmux send --surface "$SID"` typed the
probe command into the user's prompt. `send` exited 0. The only evidence was a
`surface.input_sent` frame whose `result.surface_id` was the caller's.

So: **validate the handle before sending, and confirm the target afterward.**

```bash
[[ -n "$SID" && "$SID" != "null" ]] || { echo "no surface handle — refusing to send" >&2; exit 2; }
[[ "$SID" != "$MY_SURFACE_ID" ]]    || { echo "handle resolved to my own surface" >&2; exit 2; }

SEQ=$(cmux events --snapshot 2>/dev/null | jq -r '.resume.latest_seq')
cmux send --workspace "$WS" --surface "$SID" "$MSG"
cmux events --after "$SEQ" --name surface.input_sent --limit 3 --timeout 5 \
            --no-ack --no-heartbeat 2>/dev/null \
  | jq -e --arg s "$SID" 'select(.payload.result.surface_id==$s)' >/dev/null \
  || echo "WARNING: send did not land on $SID" >&2
```

`jq -r` printing `null` for a missing key is the other half of this trap — quote
the guard against the literal string `null`, not just against empty.

## Recipe: wait for another agent to finish its turn

One blocking call, zero wake-ups, no model tokens burned while waiting:

```bash
cmux events --category agent --name agent.hook.Stop \
            --timeout 600 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg s "$SURF_ID" \
      'select(.payload.phase=="completed" and .surface_id==$s)' \
  | head -1
```

`agent.hook.SubagentStop` is the same signal for a subagent; `agent.hook.SessionEnd`
fires when the session itself exits. Note `--limit` counts **frames**, not
matches, so when a `jq` filter does the narrowing, bound the wait with
`--timeout` and terminate on the first match with `head -1` rather than
trusting `--limit 1`.

`agent.hook.SessionStart` is the counterpart for "has the agent come up yet?" —
its payload carries `session_id`, `surface_id` and `cwd`, which is also how you
map a live claude session id onto the cmux surface showing it.

## Recipe: wait for a surface to exist

```bash
cmux events --name surface.created --timeout 30 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg p "$PANE_ID" 'select(.pane_id==$p)' | head -1
```

This tells you the surface **exists**. It does not tell you its PTY is attached —
a `cmux send` is still what attaches the PTY, so the readiness probe in SKILL.md
(and `open-side-surface.sh --wait-ready`) is still required before a read.

## Recipe: a durable cursor across calls

`--cursor-file` makes a watcher resumable without tracking seq yourself: it seeds
the start from the file and writes the last seen seq back after each frame.

```bash
cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect \
            --category notification --no-ack --no-heartbeat
```

With `--reconnect` it reconnects forever and resumes from the last received seq,
which survives a cmux restart. Check `resume.gap` in the ack frame — `true` means
retention dropped frames between your cursor and the live stream, so the replay
is incomplete.
