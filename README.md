# herdr-freebuff-plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Makes [Freebuff](https://freebuff.com) a first-class agent inside [Herdr](https://herdr.dev), the terminal workspace manager for coding agents.

**Lifecycle state** (`idle` / `working` / `blocked`) is reported to the herdr pane automatically — no manual status commands. Freebuff has no hook system, so the plugin polls freebuff's per-chat files on disk and supplements that with herdr's pane `detection` buffer for the transient UI states freebuff never flushes.

## Features

- **Lifecycle reporting** — the freebuff pane shows `idle` → `working` → `blocked` → `idle` (herdr renders the green-checkmark `done` on the `working → idle` transition). Detects:
  - Normal processing turns (`working` / `idle` from `log.jsonl` timestamps)
  - `ask_user` multiple-choice popups (`blocked` from the pane detection buffer)
  - Answer chosen (`working` from the screen-detected answer echo)
  - AI processing heartbeat (`working` from `• Thinking` / `Thinking...` / `Working...`)
  - Esc abort (`idle` from the `[response interrupted]` marker)
- **Authority release** — the watcher calls `pane release-agent` when freebuff exits, so a pane can never be left showing a stale `working` or `blocked` dot.
- **Launch panes** — new task, or resume the last session.
- **Notifications** — a `notify` action sends a herdr toast.

## Requirements

- Herdr >= 0.9.1
- `freebuff` on your `PATH` (`npm i -g freebuff`)
- `node` on your `PATH` (the classifier parses freebuff's JSON in node)
- Linux or macOS. The scripts are POSIX `sh`; Windows is not supported.

## Install

From a local checkout:

```bash
herdr plugin link /path/to/herdr-freebuff-plugin
```

Or from GitHub:

```bash
herdr plugin install <owner>/herdr-freebuff-plugin
```

There is no setup step. Nothing is written outside the plugin's own config and
state directories, and nothing is added to your `PATH`.

Verify:

```bash
herdr plugin list
herdr plugin action list --plugin freebuff.integration
```

## Use

Open a freebuff pane:

```bash
herdr plugin pane open --plugin freebuff.integration --entrypoint task
herdr plugin pane open --plugin freebuff.integration --entrypoint resume-last
```

Or bind a key:

```toml
[[keys.command]]
key = "prefix+f"
type = "plugin_pane"
command = "freebuff.integration.task"
description = "Freebuff: new task"
```

Send a notification:

```bash
herdr plugin action invoke freebuff.integration.notify "Build done" "api workspace"
```

Typeing `freebuff` directly in a terminal does **not** report lifecycle state.
State reporting only happens for panes this plugin opened, which is where
`HERDR_ENV`, `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` exist. A freebuff you start
yourself shows `agent_status: unknown` in herdr — verified on a live server, not
theoretical.

### Notifications (blocked → toast + sound)

By default herdr suppresses toasts for the active tab and has notifications off.
Enable in `~/.config/herdr/config.toml`:

```toml
[ui.toast]
delivery = "herdr"
delay_seconds = 1

[ui.toast.herdr]
position = "bottom-right"

[ui.sound]
enabled = true
```

## How status reporting works

`scripts/launch.sh` is the plugin pane entrypoint. Herdr runs it as the pane's own
PTY process, so freebuff gets a real TTY. Before it `exec`s freebuff, it spawns
`scripts/status-watcher.sh` as a detached child, passing `$$`. Because `exec`
preserves the pid, that `$$` becomes freebuff's own pid, and the watcher tracks
freebuff's lifetime with a plain `kill -0` poll. When freebuff goes away, the
watcher releases its herdr source and removes its per-pane state.

There is deliberately **no PATH wrapper**. An earlier version installed a shim at
`~/.local/bin/freebuff` with the plugin's absolute path baked in at install time.
Any plugin reinstall or hash change left that shim pointing at a deleted
directory, which silently killed all state reporting while still shadowing the
real `freebuff` binary.

### Session pinning

Each pane pins **one** chat directory. "Newest chat dir" is not a stable
identity: an idle session stops touching its dir, so any other freebuff session
still writing to its own dir becomes "newest" and takes over this pane's
reported state. Measured on a live server, an idle pane flipped to `working` and
stayed there for 76 polls because an unrelated session was mid-turn.

The pin is by **writer pid**. Freebuff stamps every `log.jsonl` line with the pid
that wrote it, and `herdr pane process-info` reports the pids in a pane; the
watcher intersects the two. No cooperation from freebuff is needed.

Newest-by-mtime is the fallback only for a **brand-new** session, in the moment
before its first log line exists, and only because the mtime floor `launch.sh`
passes proves the directory was created after the pane launched. A floor of `0`
— both resume modes, and every restart re-attach — gets no fallback at all.
"Newest" cannot identify a resumed session, so those panes wait for a pid match
and report `idle` until one appears. No pin is the correct answer there: a
missing pin self-heals the moment freebuff writes its first log line, while a
wrong pin reports another session's state indefinitely.

The pin is also **re-checked**, because a pin is a snapshot and can be wrong
from the moment it is taken. Every `FREEBUFF_PIN_RECHECK_POLLS` polls (default
10) the watcher confirms the pane's pids still intersect the directory's writer
pids. After `FREEBUFF_PIN_LOSS_POLLS` consecutive mismatches (default 3) it
drops the pin and re-resolves. A single mismatch is not treated as proof, since
freebuff forking can change a pane's process group transiently; `unknown` — herdr
unreadable, or the directory has no log yet — never counts against the pin.

### One watcher per pane

Several sweeps can run at once — herdr re-reads the startup hook after a
restore, and a slow one can overlap a later one. Each sweep spawns a watcher
candidate for every marked pane, and the candidates decide between themselves:
the first one to create `watch-<pane_id>.pid` with an exclusive create (`set -C`)
owns the pane, and the losers exit immediately without reporting anything,
without a seq counter, and without touching herdr state.

The sweep's own pidfile check is only a cheap pre-check to avoid spawning a
watcher that would instantly exit. It cannot be the thing that prevents a
double-attach: read-then-write loses every race by definition.

This matters because two watchers on one pane share one seq counter. Their
`--seq` values interleave, herdr drops the out-of-order reports, and the pane
goes quiet for reasons that look like the original outage.

A slot naming a live process blocks a claim; a slot naming a dead one is
reclaimed, so a pane whose watcher was killed can still be re-attached. A slot
with no readable pid is a writer mid-update and is left alone.

### Surviving a herdr restart

A watcher dies with the pane's process tree, so a server restart used to leave
surviving freebuff panes reporting nothing — and herdr forgets the display name
too. The plugin now records an `owned-<pane_id>` marker when it launches a
session, and a startup hook re-attaches watchers to those panes after restore.

Panes you started freebuff in yourself are never adopted, even across a restart.

### State detection matrix

Screen signals come from `herdr pane read <pane> --source detection` — herdr's
live bottom-buffer snapshot, the same buffer herdr's own agent screen manifests
evaluate. When a screen signal is present it is authoritative; otherwise the
watcher falls back to the on-disk log timeline.

| State | Screen signal | File signal (used when no screen signal) |
|---|---|---|
| `blocked` | `Enter select` / `↑↓ navigate` (live popup) | `ask-user` block in the last AI message with no user reply after it |
| `working` | `Your answer:` + box, or `• Thinking` / `Thinking...` / `Working...` | `[send-message]` or `Start agent` newer than `Main prompt finished` |
| `idle` | `[response interrupted]` (Esc) | `Main prompt finished` newer than the last start, or no chat dir |

### Why screen reading?

Freebuff flushes `chat-messages.json` and `log.jsonl` only at end-of-turn.
During the live `ask_user` popup the question block is not yet on disk, so
file polling alone cannot see it. After the user answers or presses Esc, the
files stay stale — still showing the old unresolved `ask_user` block — until the
next `Main prompt finished`.

### Polling

State is checked every ~700ms (falling back to 1s where fractional `sleep` is
unsupported) against the pinned chat dir. One node process per poll returns every
file-derived signal at once; the directory scan is plain shell.

```
~/.config/manicode/projects/<project-slug>/chats/<timestamp>/
    chat-messages.json
    log.jsonl
```

## Debugging

Set `FREEBUFF_DEBUG=1` in the pane environment. The watcher then appends its
state transitions and lifecycle calls to:

```
<plugin state dir>/watcher-<pane_id>.log
```

`herdr plugin config-dir` prints the config dir; the state dir is the sibling
`state/` directory, and the watcher logs its own resolved path at startup.

Logs older than a day are pruned, along with per-pane state files belonging to
panes herdr no longer lists. The sweep runs from the plugin's startup hook and
again whenever a new watcher starts, so stale files never accumulate. It has to
be external: closing a pane makes herdr SIGKILL the pane's whole process group,
which no shell trap can intercept, so a watcher cannot clean up after itself in
that case.

### When the watcher loses herdr

A watcher whose `report-agent` calls are failing logs to the same file and to the
pane's stderr **without** `FREEBUFF_DEBUG`, because a watcher that cannot reach
herdr is indistinguishable from a pane with no plugin installed:

```
<plugin state dir>/watcher-<pane_id>.log
2026-01-01T00:00:00Z report-agent FAILED state=working (1/5 consecutive)
2026-01-01T00:00:07Z giving up on pane w1:p3: 5 consecutive report-agent failures. Watcher will exit so the startup hook re-attaches it against the new server.
```

After `FREEBUFF_REPORT_FAILURE_LIMIT` consecutive failures (default 5) the
watcher exits. It holds a pane's worth of dead state and a stale seq counter by
then, and the only thing that can fix it is exiting so the startup hook
re-attaches a fresh watcher against the new server. On the way out it clears its
own seq file and pidfile, which is what lets the sweep treat the pane as
unwatched.

The watcher also re-reports an unchanged state every `FREEBUFF_HEARTBEAT_POLLS`
polls (default 30, roughly 21s). Without that heartbeat a pane sitting idle
against a dead server would never attempt a report, and so would never notice.

## Files

| File | Role |
|---|---|
| `herdr-plugin.toml` | Manifest: startup hook, 2 panes, notify action |
| `scripts/launch.sh` | Pane entrypoint; spawns the watcher, then execs `freebuff` |
| `scripts/status-watcher.sh` | Detached per-pane watcher; reports and releases state |
| `scripts/watcher-lib.sh` | Shared classify/detect helpers (file-based + screen) |
| `scripts/common.sh` | `herdr_cmd`, `in_herdr`, `can_report`, `prune_orphan_state`, plugin root/state defaults |
| `scripts/notify.sh` | Sends a herdr notification |
| `scripts/prune-state.sh` | Startup hook; calls `prune_orphan_state` |
| `tests/` | Test suite: 7 suites, 79 cases |

## Notes

- Launching uses plugin **panes** (real PTYs). Actions run detached without a
  TTY, and freebuff requires one.
- Reports use the source id `custom:freebuff`. Herdr ignores reports whose
  `--seq` is not greater than the last accepted one for the same source, and
  `release-agent` hands authority back when the watcher exits.
- No agent-detection override is shipped. Herdr only detects agents it already
  knows, and custom state reporting explicitly does not require a recognised
  agent executable. A consequence: `herdr agent explain` returns
  `agent_explain_unavailable` for these panes, because there is no *detected*
  agent to explain. The reported state is authoritative regardless.
- Entering `idle` is debounced over three consecutive observations, so one failed
  pane read cannot flap a working pane to idle and back.

## License

MIT — see [LICENSE](LICENSE).
