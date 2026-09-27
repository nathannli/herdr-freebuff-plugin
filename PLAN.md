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

`launch.sh` writes an `owned-<pane_id>` marker when it launches a session.
`scripts/attach-watches.sh`, run from the `[[startup]]` hook after restore, walks
the live panes, skips any that already have a live watcher, and re-attaches the
rest using the freebuff pid from `pane process-info`.

Scope is the point: only panes carrying a marker are re-attached. Without that
check the sweep also adopts freebuff sessions the user started by hand and starts
writing herdr state into panes the plugin does not own. Verified live — the
sweep restored `agent=freebuff display=freebuff status=idle` on a killed-watcher
pane and left a manually started pane unregistered.

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
| `scripts/watcher-lib.sh` | `classify`, `detect_blocked`, `last_matching_ts`, `find_newest_chat`, `detect_screen_state` |
| `scripts/notify.sh` | Sends a herdr notification |
| `scripts/prune-state.sh` | Startup hook; runs the re-attach sweep |
| `scripts/attach-watches.sh` | Startup hook; re-attaches watchers to surviving plugin-launched panes |
| `scripts/common.sh` also owns `prune_orphan_state`, `live_pane_ids` | Sweeps state for dead panes and logs older than a day |

### Tests (79 cases, 7 suites, all passing)
| File | Tests |
|---|---|
| `tests/common.test.sh` | 5 (`in_herdr`, `herdr_cmd`, `can_report`) |
| `tests/e2e.test.sh` | 8 (full watcher lifecycle, source id, pin-hijack regression, release on exit) |
| `tests/launch.test.sh` | 8 (modes, watcher spawn guards, error cases) |
| `tests/notify.test.sh` | 2 (sends notification, fails outside herdr) |
| `tests/prune.test.sh` | 6 (orphan sweep, pane-id prefix safety, log pruning) |
| `tests/attach.test.sh` | 16 (debounce gate, pid pinning, floor-gated fallback, pin re-validation, `pane_freebuff_pid`, sweep scope) |
| `tests/watcher.test.sh` | 43 (classify matrix, `detect_screen_state`, `classify_signals`, `find_newest_chat`, `pane_project_slug`) |

Each e2e phase resets the herdr-stub call log before asserting, so a state
reported in an earlier phase can never satisfy a later assertion. The runner
accumulates per-suite failures instead of aborting on the first broken file.

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

## Known limitations

All were confirmed against a live herdr 0.9.1 server, not inferred.

- **Only plugin-launched panes report state.** A freebuff started any other way
  shows `agent_status: unknown` in herdr. There is no watcher for it. Verified:
  a manually started freebuff pane reports `agent: None`, `status: unknown`,
  while a plugin-opened pane reports `agent: freebuff`, `status: idle`.
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

