---
name: notify-slack
description: "Post a message to Slack from the terminal via an incoming webhook — a completion notification, a progress update, a result summary, or a Block Kit message. Covers 'ping me on Slack when this finishes', 'post that summary to Slack', 'send this to the team channel'."
when_to_use: |
  Use when the user wants something sent TO Slack:
  - "notify me on Slack when this is done", "ping the channel when the deploy finishes"
  - "post this summary to Slack", "send that to #eng"
  - "drop the results in Slack", "let the team know in Slack"
  Each configured webhook posts to one fixed channel chosen at install time —
  the payload cannot retarget it. Reading Slack is the companion `read-slack`
  skill; this one only writes.
allowed-tools: "Bash(bash */scripts/notify.sh *) Read"
---

# notify-slack

Sends a message into Slack through an **incoming webhook** — a single URL bound to one channel. That binding is the whole security model: the URL carries no account access, cannot read anything, cannot delete anything, and cannot post anywhere except the one channel its installer picked. It is the smallest possible grant for "let the agent tell me things in Slack".

The trade-off is that the destination is fixed. `channel`, `username`, and `icon` in the payload are **ignored** — Slack always uses the app's configuration. Several destinations means several webhooks (see `--to` below).

## Setup (one time)

The script needs a webhook URL and the `curl` + `jq` tools. The plugin README walks through it: create a Slack app, activate Incoming Webhooks, **Add New Webhook to Workspace**, pick the channel, copy the URL. That README is at `${CLAUDE_PLUGIN_ROOT}/README.md` — Codex: substitute the installed plugin directory for that token. Then provide the URL one of two ways:

- `export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/…`, or
- `export SLACK_WEBHOOK_OP_REF="op://Employee/Slack notify/webhook"` (1Password ref; the script resolves it via `op read` so the URL never sits in your shell env).

**The URL is a bearer secret.** Anyone holding it can post to that channel, so it never goes in a repo, an issue, or a transcript — Slack actively searches for leaked webhook URLs and revokes them. The script hands it to `curl` on stdin, so it stays out of `ps` and shell history.

## Verify the config

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --check
```

This validates deps and the URL **offline**. Incoming webhooks have no auth-check endpoint — the only way to prove a URL is still live is to post with it — so a passing `--check` does not promise delivery. Confirm that by sending one real message.

## Sending a message

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" 'Deploy finished: 4 services green, 0 rollbacks.'
```

For anything multi-line, or anything you would not want in `ps` output, use a file or stdin instead of an argument:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --text-file /tmp/summary.md
```

Slack's message markup is not Markdown — `*bold*` not `**bold**`, `<url|label>` not `[label](url)`, and no headings or tables. The full reference ships with the `collab-tools` plugin, in its `temp-draft` skill under `references/slack-formatting.md`; read it before composing anything with formatting in it.

Text is capped at 40,000 bytes (Slack's limit for a message's `text`). The script refuses longer input rather than letting Slack truncate it — post a summary with a link instead.

## Several destinations

One webhook, one channel. To reach more than one, create a webhook per channel and give each a suffixed variable:

```bash
export SLACK_WEBHOOK_URL_ALERTS=https://hooks.slack.com/services/…
export SLACK_WEBHOOK_URL_ENG=https://hooks.slack.com/services/…
```

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to alerts 'Disk at 91% on build-02.'
```

`--to <name>` reads `SLACK_WEBHOOK_URL_<NAME>` (or `SLACK_WEBHOOK_OP_REF_<NAME>`), uppercased. With no `--to`, the unsuffixed pair is used.

## Replying in a thread

A webhook post returns no timestamp, so the `ts` to reply under has to come from somewhere else — in this plugin, from the companion `read-slack` skill, whose `thread` and `history` output carries it.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --thread-ts 1763502924.627409 'Fixed in 3ecbf8920.'
```

The parent message has to be in the webhook's own channel — the webhook cannot reach any other. A `ts` from elsewhere is not something Slack documents an error for, so verify the reply landed where you meant rather than trusting the `Sent to Slack` line alone.

## Block Kit messages

For richer layout, pass a JSON **array** of blocks. `--text` becomes the notification/fallback line, which is what shows in the sidebar and push notification — always supply it.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --text 'Nightly suite: 2 failures' --blocks-file /tmp/blocks.json
```

## Before sending

Posting into a channel is outward-facing and **cannot be undone** — incoming webhooks have no delete. Two habits follow:

1. **Confirm the content and the destination with the user** before the first send of a session, and any time the message quotes someone, names a customer, or carries a log or screenshot. A request like "ping me on Slack when this finishes" authorizes that notification and the HTTPS call it needs — don't ask twice for the same one. Treat "post this to the team channel" as a publish, not a note to self.
2. **Use `--dry-run`** to inspect the exact payload and resolved destination without sending anything. It is also the first thing to reach for when Slack answers `invalid_payload`.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --dry-run --text-file /tmp/summary.md
```

A dry run is never a send. Report success only when the script prints `Sent to Slack.` — it says that only on HTTP 200 with a literal `ok` body.

## Deliberately not implemented

**No retry, no dedup journal, no receipt log.** A webhook post is one idempotent-enough HTTP call whose failures are all reported synchronously and nearly all permanent (revoked URL, archived channel, admin restriction) — retrying those just posts twice or fails twice. On the one ambiguous case, a network error mid-flight, the script says nothing was confirmed sent; check the channel rather than resending blind. Don't add exactly-once machinery here.

## When something fails

The script maps Slack's error strings to what to do about them — a revoked webhook, an archived channel, an admin restriction on this posting method. `no_service` after it previously worked usually means the URL leaked and Slack revoked it; regenerate it in the app's Incoming Webhooks settings rather than debugging the payload.
