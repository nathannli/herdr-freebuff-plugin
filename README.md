# herdr-freebuff-plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Version 0.2.0** · requires herdr >= 0.9.1 · Linux and macOS

Makes [Freebuff](https://freebuff.com) a first-class agent inside [Herdr](https://herdr.dev), the terminal workspace manager for coding agents.

**Lifecycle state** (`idle` / `working` / `blocked`) is reported to the herdr pane automatically — no manual status commands. Freebuff has no hook system, so the plugin polls freebuff's per-chat files on disk and supplements that with herdr's pane `detection` buffer for the transient UI states freebuff never flushes.

## What changed in 0.2.0

A fork of [TheMetalStorm/herdr-freebuff-plugin](https://github.com/TheMetalStorm/herdr-freebuff-plugin), whose last release was 0.1.0. Read this first if you are upgrading: **0.1.0 does not work on herdr 0.9.1**, so the version you are replacing was not reporting state at all.

### 0.1.0 was broken on herdr 0.9.1

- The reported contract no longer matched the API, and a PATH shim installed at `~/.local/bin/freebuff` pointed at a stale plugin path. The shim shadowed the real `freebuff` binary while failing silently, so every session reported nothing.
- The documented keybinding used `type = "plugin_pane"`, a key type herdr 0.9.1 does not have — `reload-config` rejects it.
- A herdr server restart killed every watcher, leaving surviving panes reporting nothing and herdr forgetting their display names. There was no startup hook to repair that afterwards.
- A freebuff you started by hand was never watched at all.

### Reporting, rewritten for the herdr 0.9.1 API

- Report and release with `--source custom:freebuff`, `release-agent` on exit, a strictly increasing `--seq` in the plugin state dir, and pane reads via `--source` detection.
- **The PATH shim is gone.** `scripts/common.sh` appends the well-known install prefixes instead, so `freebuff`, `node` and `herdr` all resolve from a pane the server spawned with launchd's default `PATH`. See [PATH in a herdr pane](#path-in-a-herdr-pane).
- **Chat-dir pinning.** 0.1.0 re-resolved the newest chat directory on every poll, so an unrelated session in the same project could keep an idle pane reporting `working`. One directory is now pinned per pane by writer pid, the newest-by-mtime fallback is gated on a non-zero launch floor, and the pin is re-checked on a slow cadence. See [Session pinning](#session-pinning).
- **One watcher per pane.** Overlapping sweeps could each attach a watcher to the same pane. The watcher now claims its pane with an atomic create, and the losers exit without reporting.
- **Failures are loud.** A watcher counts consecutive `report-agent` failures, logs them unconditionally, and exits at a limit so the startup hook re-attaches it against the current server. A watcher that just kept polling would sit on a dead socket and a stale sequence counter indefinitely.

### New

- **Manual panes are adopted.** A freebuff you started by hand is detected and watched like a plugin-launched one, instead of showing `unknown` forever. Detection matches resolved freebuff binary paths and never the substring `freebuff`, so `vim freebuff-notes.md` is not adopted. A claim lasts exactly as long as its freebuff, so the same pane can be adopted again later. Opt out globally with `no-adopt` or per pane with `no-adopt-<pane_id>`.
- **A sweep daemon.** herdr 0.9.1 exposes no cron, no scheduler and no `events.subscribe`, so pane creation cannot be hooked at all. One daemon polls every 20s so a freebuff started later is still claimed.
- **A startup hook.** On server start and after a restore, state for closed panes is swept and watchers are re-attached to surviving panes.
- **Pane state survives a restart.** The change users notice most: a restart no longer leaves live panes stuck on a stale `working` dot, or forgets their display name.

### Removed

- The `resume-named` launch mode. It passed its argument straight to `freebuff --continue`, which uses the value as a chat *directory* name and, on a miss, silently resumes the most recent chat in the project instead. Its "session id" wording invited exactly the wrong value, so it is gone rather than documented. Use `resume-last`.
- Windows support: `platforms` is now `linux` and `macos`. The scripts are POSIX `sh`.
- The `setup` action, and the two test suites that covered the old shim and setup behaviour.

### At a glance

| | 0.1.0 | 0.2.0 |
|---|---|---|
| plugin version | 0.1.0 | 0.2.0 |
| `min_herdr_version` | 0.7.0 | 0.9.1 |
| `platforms` | linux, macos, windows | linux, macos |
| panes | task, resume-last, resume-named | task, resume-last |
| startup hook | none | sweeps state, re-attaches watchers |
| session restore | claimed, never worked | **struck through** — herdr supports it, freebuff exposes no resumable id |
| test suites / assertions | 7 / 59 | 9 / 158 |

9 suites, 119 tests, 158 assertions, 0 failures on herdr 0.9.1.

## Features

- **Lifecycle reporting** — the freebuff pane shows `idle` → `working` → `blocked` → `idle` (herdr renders the green-checkmark `done` on the `working → idle` transition). Detects:
  - Normal processing turns (`working` / `idle` from `log.jsonl` timestamps)
  - `ask_user` multiple-choice popups (`blocked` from the pane detection buffer)
  - Answer chosen (`working` from the screen-detected answer echo)
  - AI processing heartbeat (`working` from `• Thinking` / `Thinking...` / `Working...`)
  - Esc abort (`idle` from the `[response interrupted]` marker)
- **Authority release** — the watcher calls `pane release-agent` when freebuff exits, so a pane can never be left showing a stale `working` or `blocked` dot.
- **Adopts manual panes** — a freebuff you started by hand is detected and watched too, so every pane reports state, not just the ones the plugin opened.
- **Launch panes** — new task, or resume the last session.
- **Notifications** — a `notify` action sends a herdr toast.

## Requirements

- Herdr >= 0.9.1
- `freebuff` reachable on `PATH`, or in one of the prefixes the plugin appends
  (see [PATH in a herdr pane](#path-in-a-herdr-pane))
- `node` reachable the same way (the classifier parses freebuff's JSON in node,
  and the watcher builds its seq counter in node)
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
type = "shell"
command = "herdr plugin pane open --plugin freebuff.integration --entrypoint task"
description = "Freebuff: new task"
```

There is no `plugin_pane` key type in herdr 0.9.1 — `server reload-config`
rejects it with `unknown variant 'plugin_pane', expected one of shell, pane,
popup, plugin_action`. A `shell` command that calls `herdr plugin pane open`
does the same thing.

Send a notification:

```bash
herdr plugin action invoke freebuff.integration.notify "Build done" "api workspace"
```

A freebuff you start by hand is **adopted**: the plugin finds it, watches it, and
the pane reports `idle` / `working` / `blocked` like any other. See
[Adopting manual panes](#adopting-manual-panes) for how detection is kept strict
and how to turn it off.

Before adoption existed such a pane showed `agent_status: unknown` forever, which
was verified on a live server rather than assumed.

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

### PATH in a herdr pane

A pane does not get your login shell's `PATH`. Panes are spawned by the herdr
*server*, and that server is usually started by launchd from herdr-gui's
LaunchAgent, which inherits launchd's default:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

On a version-managed node install that contains none of `freebuff`, `node`, or
`herdr`. So `scripts/common.sh` appends the well-known install prefixes —
`~/.local/bin`, the fnm / nvm / asdf / mise node `bin` dirs, `/opt/homebrew/bin`,
`/usr/local/bin` — to any that are missing.

It **appends** rather than prepends, and that ordering is the point: anything
already on `PATH` keeps winning, so a pane opened from a real shell is entirely
unaffected and your shell's own version selection still applies. A pane can never
be pushed onto a different `node` than the one you would have got yourself.

This runs before anything resolves a binary, so it covers the launcher's
`freebuff`, the watcher's `herdr` calls, and the classifier's `node` parse
together. Set `FREEBUFF_BIN_PATH` if freebuff lives somewhere none of those
prefixes cover.

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
— `resume-last`, and every restart re-attach — gets no fallback at all.
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
too. The plugin records an `owned-<pane_id>` marker when it launches a session
and an `adopted-<pane_id>` marker when it claims a pane you started yourself, and
a startup hook re-attaches watchers to every marked pane after restore.

Re-attachment covers adopted panes too, and that is load-bearing rather than
tidy. A SIGKILLed watcher never runs the cleanup that calls `release-agent`, so
herdr holds that pane's last reported state indefinitely. If re-attachment only
knew about `owned-` panes, an adopted pane would be skipped by it (no `owned-`
marker) *and* by the adoption sweep (already adopted), and its dot would be stuck
forever. This was observed live before the fix: panes showing `agent: freebuff`
with no watcher process anywhere.

### Adopting manual panes

A freebuff started outside the plugin has no `owned-` marker, so nothing would
ever watch it. `scripts/adopt-watches.sh` claims those panes, and a small polling
daemon runs the claim continuously.

**Detection is strict.** A pane is adopted only when `pane process-info` shows a
process whose command line resolves to a real freebuff binary:
`~/.config/manicode/freebuff`, `$FREEBUFF_BIN_PATH`, `<node-prefix>/bin/freebuff`
under fnm / nvm / asdf / mise, or `freebuff` resolved on `PATH`. Matching the
substring `freebuff` would adopt `vim freebuff-notes.md` or
`grep -r freebuff` and paint a state dot onto an unrelated session. The plugin's
own scripts are explicitly excluded.

**A claim lasts as long as the freebuff, not the pane.** The claim is recorded in
`adopted-<pane_id>` before the watcher is spawned, and keeping that watcher alive
is `attach-watches.sh`'s job. Adoption itself is never made twice while a
freebuff is running there. When that freebuff exits, the marker is dropped, so a
freebuff you start in the same pane later is adopted normally. Tying the marker to
the pane instead left a live pane that could never be adopted a second time,
which is the same permanent `unknown` adoption exists to prevent; that was
observed live before the fix.

**Pinning is pid-only for adopted panes.** An adopted pane has no launch floor,
so there is no mtime to prove a chat dir belongs to it, and "newest dir" cannot
identify a resumed session. Such a pane waits for a writer-pid match and reports
`idle` until one appears, which self-heals the moment freebuff writes its first
log line.

#### Turning adoption off

There is no `herdr plugin state-dir` subcommand; the state dir is the `state/`
sibling of the config dir `herdr plugin config-dir` prints, and each watcher logs
its own resolved path at startup.

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/freebuff.integration"

# Stop claiming new panes. Watchers already running keep running: killing one
# without releasing its herdr authority would leave a stale dot behind.
touch "$STATE_DIR/no-adopt"

# Opt a single pane out, by pane id. This does detach it: re-attachment skips
# the pane, so a watcher killed later is not replaced.
touch "$STATE_DIR/no-adopt-w1:p1"
```

`FREEBUFF_NO_ADOPT=1` in the environment has the same effect as the `no-adopt`
file, and `FREEBUFF_SWEEP_INTERVAL` (default `20`) sets the sweep period.

#### Why a daemon

The startup hook runs once per server. A freebuff you start ten minutes later
would never be claimed, and herdr 0.9.1 offers no way to hook pane creation: no
cron, no scheduler, no `events.subscribe`. So `scripts/sweep-daemon.sh` polls,
running attach → adopt every 20s. Exactly one daemon runs: it claims
`sweep-daemon.pid` with an exclusive create, and a claim held by a live process
makes every other starter back off. A dead holder's claim is reclaimed, so a
daemon killed with its server comes back on the next startup hook.

#### Registration delay is expected

A freebuff does not appear in herdr the instant it starts. The delay depends on
how the session was launched, and both paths are bounded and short.

| how the session started | what registers it | expected delay |
|---|---|---|
| a plugin pane (`prefix+f`) | `launch.sh` spawns the watcher itself | ~1s, plus freebuff's own startup (usually ~10s total to the first state) |
| typed into a pane by hand | the next sweep daemon pass | up to `FREEBUFF_SWEEP_INTERVAL` (20s), average ~12s |

After the watcher exists, the first report lands on its next poll, every 700ms.
Reporting `idle` is debounced by three consecutive polls (~2.1s) so a
`working → idle` flicker does not show up in the UI, which is the floor on any
`idle` report.

So a manually started freebuff can sit at `unknown` for up to ~22s, and that is
correct behaviour, not a missed sweep. If it is still `unknown` after a couple of
passes, adoption is the thing to check, not the poll interval.

To trade herdr calls for a snappier worst case, set `FREEBUFF_SWEEP_INTERVAL=5`
for ~7s. The cost is one `pane list` plus one `pane process-info` per candidate
pane on every pass. The variable has to be in **herdr's** environment rather than
your shell's, because the daemon inherits the environment herdr started it with
— put it in `~/.config/herdr-gui/herdr-gui.env` if herdr-gui launches the
server, or set it before starting the server yourself.

Two nearby knobs that are not the same thing: `FREEBUFF_HEARTBEAT_POLLS` (30,
~21s) re-reports the current state so herdr's does not go stale, and is a
keepalive rather than a registration delay; and the idle debounce above is a
floor on reporting, not on discovery.

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
panes herdr no longer lists. The sweep runs from the plugin's startup hook, from
every pass of the sweep daemon, and again whenever a new watcher starts, so stale
files never accumulate. It has to be external: closing a pane makes herdr SIGKILL
the pane's whole process group, which no shell trap can intercept, so a watcher
cannot clean up after itself in that case.

The sweep daemon logs its lifecycle to `<state dir>/sweep-daemon.log`, and only
when `FREEBUFF_DEBUG` is set. `FREEBUFF_NO_DAEMON=1` suppresses it; the test
runner sets that, because a long-lived daemon inheriting the suite's environment
would prune against a stale view of the world.

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
| `scripts/prune-state.sh` | Startup hook; attach + adopt, then starts the sweep daemon |
| `scripts/adopt-watches.sh` | Claims panes running a freebuff the user started by hand |
| `scripts/sweep-daemon.sh` | Polls attach → adopt so later panes are claimed too |
| `tests/` | Test suite: 9 suites |

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
