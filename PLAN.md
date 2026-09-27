# Plan: freebuff → herdr integration

## Decision A (locked in)
The plugin **never sends `done`** through `pane.report-agent`. That RPC only
accepts `idle|working|blocked|unknown`. After a finished turn it sends `idle`;
herdr's built-in `working → idle` transition renders the green-checkmark `done`
state, then flips to `idle` once the tab is viewed.

## Decision B (locked in, 0.2.0)
There is **no PATH wrapper**. Earlier versions installed a shim at
`~/.local/bin/freebuff` with the plugin's absolute path baked in at install time.
A plugin reinstall changes the managed checkout hash, which left the shim
pointing at a deleted directory: the watcher failed to spawn, its stderr went to
`/dev/null`, and the plugin reported nothing while still shadowing the real
`freebuff` binary. State reporting now starts and stays inside the herdr pane.

## Decision C (locked in, 0.2.0)
No agent-detection override is shipped. Two reasons:

1. The override belongs at `~/.config/herdr/agent-detection/<agent>.toml`, not
   under the plugin config dir. The old seeding wrote to a path herdr never
   reads, so it never took effect.
2. Herdr only patches detection rules for agents it already knows how to
   identify. Adding a brand-new agent still requires a herdr binary update.

Custom lifecycle reporting explicitly does not require a recognised agent
executable, so the override was never needed.

## Decision D (locked in, 0.2.0)
The watcher **pins one chat dir per pane by writer pid, and re-checks the pin
rather than trusting it forever**.

"Newest chat dir" is not a stable identity. An idle session stops touching its
dir, so any other freebuff session still writing to its own dir becomes "newest"
and takes over this pane's reported state. Confirmed live: a freshly launched,
idle freebuff reported `idle` for three polls, then flipped to `working` and
stayed there for 76 consecutive polls because an unrelated session in another
pane kept its dir newer.

The fix needs no cooperation from freebuff beyond what it already writes.
Every `log.jsonl` line carries the pid of the process that wrote it, and
`herdr pane process-info` reports the pids in a pane. The watcher intersects the
two and pins the matching directory. Verified live: the pane's freebuff pids
were `7081 7070`, and the pinned directory's log was stamped `7081`, while a
concurrently active unrelated session kept a newer mtime and was correctly
ignored.

Supporting layers, in order of how much they matter:

1. **Writer-pid match** (load-bearing). Falls back to newest-by-mtime only for a
   brand-new session that has not written a log line yet.
2. **Project slug.** The pane's working directory, via `herdr pane get`.
3. **mtime floor.** `launch.sh` passes `Date.now()` for a new session. A resumed
   session passes `0`, because it legitimately reuses a dir created earlier.
   Compared at second resolution, since `stat` only resolves whole seconds.

A floor of `0` disables the newest-by-mtime fallback entirely. `resume-last`,
`resume-named`, and every restart re-attach all pass `0`, and "newest" cannot
identify a resumed session: an idle session stops touching its dir, so a
concurrently active session in the same project is newer. Those panes report
`idle` until a pid match appears. That is the right trade, because a missing pin
self-heals the moment freebuff writes its first log line whereas a wrong pin
reports another session's state indefinitely.

A pin is a snapshot, so it is re-checked: every `FREEBUFF_PIN_RECHECK_POLLS`
polls (default 10) the watcher confirms the pane's pids still intersect the
directory's writer pids, and drops the pin after `FREEBUFF_PIN_LOSS_POLLS`
consecutive mismatches (default 3). Debounced, because freebuff forking can
change a pane's process group transiently and a single bad poll must not cost a
working session its pin. `unknown` — herdr unreadable, or no log in the directory
yet — never counts against the pin, so a herdr hiccup cannot unpin a correct
pin.

## Architecture

### One entrypoint
Herdr runs the plugin pane entrypoint as the pane's own PTY process, so
freebuff gets a real TTY. Actions and the CLI have no TTY and cannot launch
interactive agents — which is why these are panes, not actions.

```
herdr pane  ->  scripts/launch.sh  ->  spawn status-watcher.sh (detached)
                                  ->  exec freebuff
```

`launch.sh` passes `$$` to the watcher. `exec` preserves the pid, so that value
becomes freebuff's own pid and the watcher's `kill -0` loop tracks freebuff's
real lifetime.

### Surviving a herdr restart
A watcher is a child of the pane's process tree, so a server restart kills every
watcher while the panes and their freebuff processes survive. Those panes then
reported nothing until the user relaunched freebuff by hand, and herdr had also
forgotten the display name.

`launch.sh` writes an `owned-<pane_id>` marker when it launches a session, and
`scripts/adopt-watches.sh` writes `adopted-<pane_id>` when it claims a pane the
user started by hand. `scripts/attach-watches.sh`, run from the `[[startup]]` hook
after restore and from every sweep-daemon pass, walks the live panes, skips any
that already have a live watcher, and re-attaches the rest using the freebuff pid
from `pane process-info`.

Scope is the point: only panes carrying a marker are re-attached. Without that
check the sweep also adopts freebuff sessions the user started by hand and starts
writing herdr state into panes the plugin does not own. Verified live — the
sweep restored `agent=freebuff display=freebuff status=idle` on a killed-watcher
pane and left a manually started pane unregistered.

Both markers are in scope, and that is load-bearing rather than tidiness. A
SIGKILLed watcher never runs the cleanup that calls `release-agent`, so herdr holds
the last reported state forever. With `owned-` alone, an adopted pane was skipped
by the attach sweep (no `owned-` marker) and by the adoption sweep (already
adopted), so nothing replaced its watcher and its dot was stuck permanently. Seen
live before the fix: panes reporting `agent: freebuff` with no watcher process
anywhere. `tests/adopt.test.sh` now pins this with a SIGKILL-then-re-attach case
that fails against the `owned-`-only version.

### Adopting panes the user started

`scripts/adopt-watches.sh` claims panes the plugin did not launch. It is the only
place the plugin writes herdr state into a pane it does not own, so the gating is
the design:

1. **Detection is strict.** `pane_freebuff_pid` matches resolved freebuff binary
   paths — `~/.config/manicode/freebuff`, `$FREEBUFF_BIN_PATH`, `<prefix>/bin/
   freebuff` under fnm/nvm/asdf/mise, and `freebuff` resolved on `PATH` — not the
   substring `freebuff`. A substring match adopts `vim freebuff-notes.md` and
   `grep -r freebuff`; anti-vacuity was checked by reverting to it and watching
   three lookalikes get adopted. The plugin's own scripts are excluded too. A false
   negative just leaves `unknown`, which is the status quo.
2. **Pinning is pid-only.** An adopted pane has no launch floor, so there is no
   mtime that proves a chat dir is its own, and newest-by-mtime cannot identify a
   resumed session. It waits for a writer-pid match and reports `idle` until one
   appears.
3. **Adoption is once, visible, and reversible.** The `adopted-` marker is written
   *before* the watcher is spawned, so a sweep that dies between the two does not
   cause a second adoption. `no-adopt` stops new claims, `no-adopt-<pane_id>`
   detaches one pane, `FREEBUFF_NO_ADOPT=1` does the first from the environment.
   Turning adoption off does not kill existing watchers: a watcher stopped without
   releasing its herdr authority leaves a stale dot, which is worse than a live
   watcher on an unwanted pane.

Adoption and attachment are separate steps on purpose. Adoption is a one-way
decision to write state into a pane the user owns; attachment is idempotent
bookkeeping over claims that already exist.

### Why a polling daemon

The startup hook runs once per server, so a freebuff started later would never be
adopted. herdr 0.9.1 exposes no cron, no scheduler, and no `events.subscribe`, so
pane creation cannot be hooked at all — polling is the only option.
`scripts/sweep-daemon.sh` runs prune → attach → adopt every
`FREEBUFF_SWEEP_INTERVAL` seconds (default 20). One daemon runs: it claims
`sweep-daemon.pid` with `set -C`, and a claim held by a live process makes every
other starter exit. A dead holder's claim is reclaimed, so a daemon killed with
its server returns on the next startup hook.

### Reporting contract
- Source id `custom:freebuff`, agent label `freebuff`. Stable and unique per
  integration, as herdr requires.
- Strictly increasing `--seq` per pane, stored under
  `HERDR_PLUGIN_STATE_DIR`. Herdr drops reports that are not newer.
- `pane release-agent` on watcher exit, so the pane cannot keep a stale
  `working`/`blocked` dot after freebuff dies.
- `pane report-metadata` with source `custom:freebuff-display` for the visible
  name. Display only — it never carries lifecycle authority.
- Reports only when `HERDR_ENV=1`, `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` are
  all present. No-op everywhere else.

### classify() precedence
Screen first, files second. Freebuff flushes chat files only at end-of-turn, so
file-based state is stale during exactly the windows that matter.

1. `herdr pane read <pane> --source detection` — herdr's live bottom-buffer
   snapshot, the same buffer herdr's own agent screen manifests evaluate.
2. A screen signal is authoritative:
   - `Enter select` / `↑↓ navigate` → `blocked`
   - `[response interrupted]` → `idle`
   - `Your answer:` + box, or `• Thinking` / `Thinking...` / `Working...` → `working`
3. No screen signal → the popup is visually absent, so any file-based `blocked`
   would be stale. Use the `log.jsonl` timeline directly.
4. No `pane_id` at all (tests, out-of-pane use) → file-based detection,
   including the `ask_user` block check from `chat-messages.json`.

## Files

### Core scripts
| File | Role |
|---|---|
| `herdr-plugin.toml` | Manifest: startup hook, 2 panes, notify action |
| `scripts/common.sh` | `herdr_cmd`, `in_herdr`, `can_report`, plugin root/state defaults |
| `scripts/launch.sh` | Pane entrypoint; spawns watcher, execs `freebuff` |
| `scripts/status-watcher.sh` | Per-pane poller; reports and releases state |
| `scripts/watcher-lib.sh` | `classify`, `detect_blocked`, `last_matching_ts`, `find_newest_chat`, `detect_screen_state`, `freebuff_paths`, `pane_freebuff_pid` |
| `scripts/notify.sh` | Sends a herdr notification |
| `scripts/prune-state.sh` | Startup hook; attach + adopt, then starts the sweep daemon |
| `scripts/attach-watches.sh` | Re-attaches watchers to every claimed (`owned-`/`adopted-`) pane |
| `scripts/adopt-watches.sh` | Claims panes running a freebuff the user started by hand |
| `scripts/sweep-daemon.sh` | Polls prune → attach → adopt so later panes are claimed too |
| `scripts/common.sh` also owns `prune_orphan_state`, `live_pane_ids` | Sweeps state for dead panes and logs older than a day |

### Tests (9 suites, all passing)
| File | Tests |
|---|---|
| `tests/common.test.sh` | 5 (`in_herdr`, `herdr_cmd`, `can_report`) |
| `tests/e2e.test.sh` | 8 (full watcher lifecycle, source id, pin-hijack regression, release on exit) |
| `tests/launch.test.sh` | 8 (modes, watcher spawn guards, error cases) |
| `tests/notify.test.sh` | 2 (sends notification, fails outside herdr) |
| `tests/prune.test.sh` | 6 (orphan sweep, pane-id prefix safety, log pruning) |
| `tests/attach.test.sh` | 21 (debounce gate, pid pinning, floor-gated fallback, pin re-validation, `pane_freebuff_pid` lookalikes, sweep scope, concurrent-sweep race, claim primitive) |
| `tests/adopt.test.sh` | 15 (path resolution, lookalike and own-script rejection, adoption + marker, no re-adoption, `owned-` panes untouched, `no-adopt` / `FREEBUFF_NO_ADOPT` / per-pane opt-out, adopted-marker sweep, re-attach after SIGKILL, opt-out detach) |
| `tests/watcher.test.sh` | 43 (classify matrix, `detect_screen_state`, `classify_signals`, `find_newest_chat`, `pane_project_slug`) |

Each e2e phase resets the herdr-stub call log before asserting, so a state
reported in an earlier phase can never satisfy a later assertion. The runner
accumulates per-suite failures instead of aborting on the first broken file, and
exports `FREEBUFF_NO_DAEMON=1`: a long-lived daemon would inherit the suite's
environment and prune against a stale view of the world.

## Key commands
- **Link**: `herdr plugin link /path/to/herdr-freebuff-plugin`
- **Open a pane**: `herdr plugin pane open --plugin freebuff.integration --entrypoint task`
- **Notify**: `herdr plugin action invoke freebuff.integration.notify "title" "body"`
- **Test**: `sh tests/run.sh`
- **Plugin logs**: `herdr plugin log list --plugin freebuff.integration`
- **Config dir**: `herdr plugin config-dir freebuff.integration`
- **Watcher debug log**: set `FREEBUFF_DEBUG=1` in the pane, then read
  `<config dir>/watcher-<pane_id>.log`. Report failures are written to that same
  log, and to the pane's stderr, with no debug flag needed.

## Decision E (locked in, 0.2.0)
**One watcher per pane, arbitrated by an atomic claim held by the watcher
itself.**

The sweep used to read the pidfile, run `kill -0`, and then spawn. That is
check-then-act: two concurrent sweeps both see no live watcher, both pass, and
two watchers share a pane. They then race on the seq file, so their `--seq`
values interleave, herdr drops the out-of-order reports, and the pane goes quiet
for reasons indistinguishable from the original outage.

Two designs were tried and measured before this one:

1. **Claim on the sweeper's behalf, record the spawned pid afterwards.** Failed.
   The claim was held under the sweeper's pid, which exits milliseconds later, so
   a competing sweep could read a dead holder inside the claim-to-record window.
   Reclaim was also read-check-then-`rm`, so a loser that had read the dead pid
   could delete the winner's freshly recorded slot and win the recreate. Measured
   at 2 winners from 6 concurrent sweeps.
2. **The watcher claims for itself.** The claim is a single exclusive create
   performed by the process that will occupy the slot, so there is no window to
   race in. Measured at exactly 1 live watcher, 1 seq file, and a strictly
   increasing seq stream from 6 concurrent sweeps.

A slot naming a live process blocks a claim; a dead one is reclaimed so a killed
watcher's pane can still be re-attached; an unreadable one is a writer
mid-update and is left alone. The sweep's `attached N watcher(s)` line became
`spawned N watcher candidate(s)`, because under overlapping sweeps the number of
candidates is deliberately larger than the number of panes attached.

## Known limitations

All were confirmed against a live herdr 0.9.1 server, not inferred.

- **Manual panes are adopted, but conservatively.** A freebuff started by hand is
  watched like any other. Before adoption it reported `agent: None`,
  `status: unknown`; verified live. Adoption needs strict binary-path detection,
  so an unusual freebuff install that resolves to none of the known prefixes
  stays `unknown` rather than being adopted on a guess. `FREEBUFF_BIN_PATH`
  overrides the resolved set.
- **A resumed pane can sit at `idle` before it pins.** `resume-last` and
  `resume-named` pass a floor of `0`, which disables the newest-by-mtime
  fallback, because "newest" cannot identify a resumed session and a wrong pin
  is worse than none. The pane reports `idle` until freebuff writes a log line
  carrying its pid, which is immediate in practice but is a real window. Closing
  it entirely needs freebuff to expose its session id on the command line.
- **No native session identity is reported**, so herdr cannot auto-resume a
  freebuff pane after a server restart. `resume_agents_on_restore` has nothing
  to resume from until the plugin reports `--agent-session-id`.
- **A watcher that loses herdr gives up rather than retrying forever.** It counts
  consecutive `report-agent` failures, logs them unconditionally, and exits at
  `FREEBUFF_REPORT_FAILURE_LIMIT` (default 5) so the startup hook re-attaches it
  against the new server. A brief blip is survivable because the counter resets
  on the first success. A watcher that instead kept polling would sit on a stale
  socket and a stale seq counter indefinitely, which is the silent-failure mode
  that made the original outage hard to diagnose. The cost is that a herdr
  restart longer than ~5 polls leaves a pane unwatched until the startup hook
  runs again.
- **Detection is a poll, not a subscription.** `events.subscribe` on
  `pane.agent_status_changed` would be event-driven, but freebuff exposes no
  hooks to drive it.
- **The watcher cannot clean up when its pane is closed.** Herdr tears the pane's
  whole process group down with SIGKILL, which no shell trap intercepts, so the
  watcher's own state files survive. The release is unnecessary there because
  herdr drops the agent with the pane. `prune_orphan_state()` sweeps the
  leftovers from the startup hook and at every watcher startup, so they never
  accumulate.

