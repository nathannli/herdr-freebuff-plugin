# Test Notes / Known Deviations

## State semantics
Herdr's state vocabulary (confirmed via schema):
  - `blocked` = agent needs input/approval/decision
  - `working` = actively running
  - `done`    = finished, unseen by user
  - `idle`    = finished/waiting, seen
  - `unknown` = cannot classify

The plugin never reports `done` via `pane.report-agent` (that RPC only accepts
`idle|working|blocked|unknown`). Instead, it reports `idle` when a turn finishes,
and herdr internally renders the `done` state (green checkmark) during the
`working -> idle` transition.

## Reporting contract under test
- Source id is `custom:freebuff`; the e2e suite asserts it, because a source
  change silently orphans the pane's lifecycle authority.
- `pane release-agent` on watcher exit is asserted, along with removal of the
  per-pane seq file. Without the release, a pane keeps its last reported state
  after freebuff dies.
- `can_report` gates every spawn: `HERDR_ENV=1`, `HERDR_PANE_ID` and
  `HERDR_SOCKET_PATH` must all be present. `tests/run.sh` exports a fake socket
  path so the guard matches a real managed pane; the herdr stub never connects
  to it.

## How Herdr renders the 5 states (observed via schema + opencode plugin)
- `working`  -> orange/yellow filled dot
- `done`     -> green unfilled dot
- `blocked`  -> filled dot glyph
- `idle`     -> minimal/empty
- `unknown`  -> red marker

The `label()` call (`report-metadata --display-agent freebuff`) runs once at
watcher startup. It is display-only and never carries lifecycle authority.

## Detection buffer, not viewport
`detect_screen_state` reads `--source detection`, herdr's live bottom-buffer
snapshot. `--source visible` is the scrolled viewport and misses content the
agent has scrolled past. The herdr stub serves the same fixture content for any
`--source`, so the distinction is not exercised by the stub; it is a contract
choice, not a tested behaviour.

`herdr agent explain` returns `agent_explain_unavailable` for these panes. That
is expected, not a failure: there is no *detected* agent to explain, because the
plugin ships no agent-detection override. The lifecycle source is authoritative.

## File-polling approach (not hooks)
Freebuff has no hook system. This plugin polls files at
`~/.config/manicode/projects/<slug>/chats/<timestamp>/`. The polling interval is
0.7s, falling back to 1s where fractional `sleep` is unsupported, which means
state changes are reported within ~1s of happening.

## Fake freebuff binary
The test fixture `tests/fixtures/bin/freebuff` is a simple `sleep` loop. It does
not write real chat files. Tests create fixture state files manually via
`make_fake_chat`.

## Process tracking
The watcher checks `kill -0 "$FREEBUFF_PID"` to detect when freebuff exits. The
pid is `launch.sh`'s own `$$` at spawn time, which `exec` turns into freebuff's
pid. The e2e suite starts the watcher against a stand-in process rather than
killing a real one, because killing real processes is fragile in test
environments.

## e2e log handling
Each e2e phase truncates the herdr-stub call log before acting, so an assertion
can only be satisfied by a report made during that phase. The watcher needs up
to one poll interval to react, so each phase waits 3s.

## Pin re-validation
A pin is a snapshot, so the watcher re-checks it: every
`FREEBUFF_PIN_RECHECK_POLLS` polls it confirms the pane's pids still intersect
the pinned directory's writer pids, and after `FREEBUFF_PIN_LOSS_POLLS`
consecutive mismatches it drops the pin and re-resolves.

`chat_dir_still_ours` prints `unknown` rather than `no` when either side cannot
be read, and `unknown` never counts against the pin. Without that distinction a
herdr hiccup — or a `pane process-info` that returns nothing while the pane is
busy — would unpin a correct pin. The re-check runs on a slow cadence rather
than every poll because each one is a herdr call.

The mtime fallback is gated on a non-zero floor. `resume-last` and every
restart re-attach all pass `0`, and "newest dir" cannot identify a
resumed session, so those panes must wait for a pid match rather than risk
another session's state. The test for this asserts the fallback returns *empty*
with floor `0`; the "falls back to newest" case now needs a real floor.

`touch -t` with a future timestamp silently clamps to the current time on BSD,
and `date -j -f %Y%m%d%H%M` does not agree with `touch -t` to the second. A
fixture built from either one becomes a function of when the suite runs. Read
the mtime back with `stat` and derive the floor from that.

## One watcher per pane
Assert the *outcome*, not the spawn count. Under overlapping sweeps every sweep
deliberately spawns a candidate and the losers exit, so counting spawns is
counting something that is supposed to exceed one. The invariants that matter
are one live watcher, one seq file, and a strictly increasing seq stream.

The seq assertion is the one that actually catches the bug. Reverting just the
watcher's claim leaves one live watcher by luck of timing but two watchers
sharing the counter, which shows up as a seq that goes backwards. Checking
"one live watcher" alone would have passed.

Two designs failed before the current one, both measured:
- Claiming on the sweeper's behalf and recording the spawned pid afterwards
  gave 2 winners from 6 sweeps. The claim was held under the sweeper's pid,
  which exits immediately, and reclaim was read-check-then-`rm`, so a loser
  could delete the winner's new slot and win the recreate.
- The fix is one exclusive create (`set -C`) performed by the watcher itself,
  so there is no second step to race.

`set -C` gives an atomic create, so the kernel picks the winner. Reading the
holder to decide whether a slot is stale is inherently racy, which is why the
reclaim path must end in the same exclusive create rather than trusting the
read.

`record_watch_slot` renames a written temporary over the slot. Plain `> file`
truncates first, and a claimer that observed the empty window would refuse a
valid slot, costing a re-attach.

## Session pinning
The watcher pins one chat dir per pane and never re-resolves it, by writer pid.
`make_fake_chat` therefore takes a writer pid and stamps it into `log.jsonl`,
exactly as freebuff does, and the herdr stub reports that same pid from
`pane process-info`. A regression fixture using a different pid models a
concurrent session precisely.

The e2e suite models a session the way freebuff actually writes: one chat dir
whose contents change as the turn progresses. It then plants an unrelated
mid-turn dir written by a different pid, with a strictly newer mtime, and asserts
the watcher does not follow it.

That regression is not hypothetical. On a live server an idle pane reported
`idle` for three polls, then flipped to `working` and stayed there for 76
consecutive polls because an unrelated session in another pane kept its dir
newer. The old suite would not have caught it: it advanced phases by creating a
*newer* chat dir each time, which is the exact behaviour the pinning removed.

`stat` resolves whole seconds, so the floor passed from `launch.sh` in
milliseconds is compared at second resolution. Fixtures that need an ordering
pin explicit mtimes with `touch -t` rather than relying on creation order.

## Parsing `pane list`
`herdr pane list` prints the whole panes array on one line. A greedy
`sed 's/.*"pane_id"..."/\1/p'` therefore yields only the *last* pane id, which
made the restart sweep attach to one arbitrary pane. `live_pane_ids()` parses it
with node instead, and `pane_is_live` matches whole lines so `w1:p1` cannot
match `w1:p11`.

## Restart re-attach scope
The sweep only touches panes the plugin has already claimed: an `owned-<pane_id>`
marker (launched by `launch.sh`) or an `adopted-<pane_id>` marker (claimed by
`adopt-watches.sh`). Without that check it adopted a freebuff the user had
started by hand and began writing herdr state into a pane the plugin does not
own. The scope test asserts both halves: our pane gets a watcher, the unmarked
one does not.

Both markers are in scope because of a bug this suite now pins. A SIGKILLed
watcher never runs the cleanup that calls `release-agent`, so herdr holds the
pane's last reported state indefinitely. With `owned-` alone, an adopted pane was
skipped by the attach sweep *and* by the adoption sweep, so nothing replaced its
watcher and its dot was stuck permanently — observed live as panes reporting
`agent: freebuff` with no watcher process anywhere. The regression test adopts a
pane, `kill -9`s its watcher, re-runs the attach sweep, and asserts a live
watcher exists afterwards. Reverting the scope to `owned-`-only makes exactly
that test fail.

The fake freebuff pid in these tests must be a process that actually exists. With
a nonexistent pid the spawned watcher exits immediately and cleans up its own
pidfile, which reads as "attach failed" rather than "target already gone".

## Adoption
`tests/adopt.test.sh` is mostly about what must *not* be adopted, because
adoption is the one place the plugin writes herdr state into a pane it does not
own.

Detection matches resolved freebuff binary paths, so the suite asserts rejection
of `vim freebuff-notes.md`, `grep -r freebuff`, and
`sh …/freebuff-backup.sh`, plus the plugin's own four scripts. Anti-vacuity was
checked by reverting `pane_freebuff_pid` to a substring match: all three
lookalikes were then wrongly adopted. That is the only assertion in the suite
that would have passed against the old loose matcher.

The fixtures moved from `/Users/x/…` and `/usr/local/bin/freebuff` to
`${HOME}/.config/manicode/freebuff` when the matcher went strict. A hardcoded
foreign path passes only under a substring match, so the old fixture was
asserting the bug.

An adopted pane has no launch floor, so it is spawned with floor `0` and waits
for a writer-pid match before pinning. It reports `idle` until then, which
self-heals the moment freebuff writes its first log line.

## A claim is on a freebuff, not on a pane
`adopt-watches.sh` originally skipped any pane carrying an `adopted-` marker,
which reads as sensible idempotence and is not. `prune_orphan_state` only clears
state for panes herdr no longer lists, so a *live* pane whose freebuff had exited
kept its marker forever, every later sweep skipped the pane, and a freebuff
started there again was never adopted — permanently `agent_status: unknown`.
Found live on `w1Z:p1` after a server restart, with a dead watcher pidfile
alongside the stale marker.

Two details the fix depends on, both of which the regression test pins:

- The freebuff lookup has to run *before* the watcher-pidfile pre-check. The
  marker is a claim on a process, so answering "is the claim still valid" cannot
  depend on whether a watcher happens to be alive, or a stale claim outlives the
  thing it names whenever the old watcher is still running.
- The marker has to be (re)written *before* that same pre-check continues. If a
  live watcher causes an early `continue` before the marker is written, an
  adopted pane ends up with no marker at all, and a missing marker is exactly
  what `attach-watches.sh` reads to decide a pane is still claimed.

The test adopts a pane, swaps the stubbed pane process for a plain shell, runs a
sweep, asserts the marker is gone, `kill -9`s the watcher the way a restart does,
puts a freebuff back, and asserts a live watcher. Reverting the script makes both
assertions fail.

## The sweep daemon
`tests/run.sh` exports `FREEBUFF_NO_DAEMON=1`. A daemon started by a suite would
outlive the run, inherit the stub environment, and keep sweeping a stale pane
list — deleting state files other suites are still asserting on. `prune-state.sh`
honours the variable and skips starting it.

Note that the daemon is not covered by an automated test of its own: it is
long-lived by design, and a test that starts one has to tear it down by pid,
which is the same fragile pattern the suite avoids elsewhere. Its single-instance
claim and kill switch were verified by hand against a live server.

The daemon's loop runs `attach-watches.sh` then `adopt-watches.sh`, and must not
run `prune-state.sh`. That is not a style preference. `prune-state.sh` is the
startup hook, and the hook starts a daemon, so a daemon invoking it spawns a
competing daemon on every pass — each one to find the claim held and exit again.
It also runs attach and adopt itself, so the old three-line loop did both jobs
twice. Caught live, as a daemon-spawned `prune-state.sh` with its own
`attach-watches.sh` child. Pruning is not lost: `attach-watches.sh` calls
`prune_orphan_state` on its first line. No test pins this, because the only honest
test starts a real daemon; keep the comment in `sweep-daemon.sh` if the loop is
ever touched.

## What `freebuff --continue` actually accepts
`--continue [conversation-id]` is the only resume surface freebuff 0.1.2 exposes.
The question that mattered was whether the `cli:<uuid>` `instanceId` from
`~/.config/manicode/freebuff-live-<pid>.json` could be handed to it, which would
have made `--agent-session-id` worth reporting. It cannot. The resolver in the
binary is:

```js
let J = join(bV(), "chats"), H = join(J, T.trim());
if (existsSync(H) && statSync(H).isDirectory()) A = H;
else RA.debug({candidateDir: H, chatId: T},
  "Requested chatId directory not found, falling back to most recent chat directory");
```

with `bV()` = `join(configDir, "projects", basename(projectRoot))`. Three
consequences, none of them visible from `--help`:

- The id is used **verbatim as a directory name**, so the conversation id is the
  chat directory name (`2026-09-27T16-47-17.277Z`) — which is what freebuff
  itself prints on exit. There is no `cli:${...}` template literal in the binary.
- **A miss is silent.** It falls back to the most recent chat in the project at
  debug log level, with no user-visible error. A plausible-looking wrong value
  resumes the wrong conversation.
- **It is project-scoped.** Only `projects/<basename(cwd)>/chats/` is searched, so
  resuming requires the same cwd basename.

This is why the undeclared `resume-named` launch mode was deleted rather than
documented. It passed its argument straight to `--continue` and its error message
called that argument a "session id", which is precisely the value a reader would
have pulled from `freebuff-live-<pid>.json` — and that paste resumes the wrong
chat without complaint. The launch suite now asserts `resume-named` is rejected
as an unknown mode. Keep that assertion if the mode ever comes back: any
replacement needs to validate the directory exists and fail loudly.

Also settled here: freebuff has no `--agent-session-id` and no
`resume_agents_on_restore`, so herdr has no session identity to restore from. The
`idle`-before-pin window on a resumed pane is not closable from the plugin side.

## A pane's PATH is not a shell's PATH
Herdr panes are spawned by the herdr *server*, not by your shell, and that server
is normally started by launchd from herdr-gui's LaunchAgent. Its PATH is
launchd's default, `/usr/bin:/bin:/usr/sbin:/sbin`, which on a version-managed
node install resolves none of `freebuff`, `node`, or `herdr`. Verified on this
machine with `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`.

All three matter, which is why the repair is one shared call in `common.sh` rather
than a `freebuff` lookup in `launch.sh`: without `node` the watcher's `next_seq`
and the classifier both fail, so a pane would open and then never report — a
different-looking bug entirely. The launch test asserts the launcher finds
freebuff under that exact PATH, and that the failure message names `node` when
it is also missing.

`augment_path` appends. The first version prepended, and
`tests/common.test.sh` caught it: prepending lets a fallback directory outrank a
binary the user had already resolved, so a pane would silently run a different
version than their shell would have. The test asserts PATH order is preserved and
fallbacks land after it.

Two fixture traps worth remembering. A `: > node` placeholder is not enough:
`command -v` skips a non-executable file, so the test fails for a reason that has
nothing to do with PATH. And an unexpanded glob must never reach PATH, so the
"no version managers installed" case asserts no literal `*` appears.

Ordering inside `common.sh` is load-bearing and was wrong once: the `augment_path`
call sat *above* its definition, so sourcing the file printed
`augment_path: command not found` and silently did nothing. Shell resolves at call
time, so the call has to come after.

## Detaching background processes from a tool call
Not a property of the plugin, but it cost real time to learn and will cost it
again. A long-lived process started from a tool call is reaped when that call's
process group is torn down, and `nohup setsid … &` does not reliably prevent it:
a control `nohup sh -c 'sleep 300'` survived while the daemon wrote no pidfile
at all. A detached wrapper script worked. The same reap kills foreground test
runs of ~200s, so the suite is run in per-suite batches instead. Live watchers
and the daemon started this way die between calls; herdr's own startup hook
reparents them properly, which is the environment that actually matters.

## Losing herdr
Every herdr call in the watcher ends in `>/dev/null 2>&1`, which is what let a
watcher talking to a dead server look exactly like a pane with no plugin
installed: no output, no exit, no state change. The watcher now counts
consecutive `report-agent` failures, writes them to the debug log and stderr
*without* `FREEBUFF_DEBUG`, and exits at the limit so the startup hook re-attaches
it. The counter resets on the first success, so a single blip is survivable.

The heartbeat exists because of a subtlety in that counter: it only advances when
a report is attempted, and reports were only attempted on a *state change*. A
pane sitting idle against a dead server would never change state, never report,
and never discover the server was gone — the exact case the counter was added to
catch. `tests/report-fail.test.sh` asserts both halves: it fails on the old
code, where the watcher neither logs nor exits and leaves its seq file and
pidfile behind.

`report()` calls `next_seq` inside the `if` condition, so a failed report still
consumes a seq number. That is harmless: herdr only requires the seq to increase,
and burning a number keeps the next attempt monotonic.

## Test-process hygiene
A suite that spawns background processes must reap only its own. A bare `wait`
blocks on anything else the runner left running, and a fake process that
outlives the suite holds the inherited stdout open, hanging the caller on a pipe
nothing writes to. `tests/report-fail.test.sh` tracks its fakes in `LIVE_FAKES`
and tears down at the start of each `setup_watcher`, since it calls setup more
than once.

## Signal handling
Closing a pane makes herdr tear down the pane's whole process group down with
SIGKILL. No shell trap intercepts that, so the watcher cannot clean up after
itself in that case — verified live: the watcher exits with no cleanup log line
and its seq file survives. The release is not needed there, because herdr drops
the agent along with the pane. `prune_orphan_state()` sweeps the leftovers and
runs both from the startup hook and at every watcher startup.

`cleanup()` ordering is load-bearing twice: `next_seq` must be read before the
`rm` of the seq file, because `next_seq` writes it and would otherwise recreate
the file it just deleted.

The same SIGKILL is what makes re-attachment cover adopted panes: herdr holds the
last reported state when no live authority holder ever releases it, so a pane
whose watcher was killed needs a replacement watcher, not a release.

## Stub fidelity
The herdr stub accepts flags real herdr rejects. `herdr pane get` takes no
`--json` and errors on it, while the stub silently swallowed it, so a test
passed against a code path that could not work in production. `pane_project_slug`
now has a test asserting the exact argv reaches the stub, by grepping the stub
call log for the forbidden flag.

`HERDR_STUB_FAIL_REPORT=1` makes `pane report-agent` exit nonzero, modelling a
server that is gone. Without it the stub always succeeds and no test can observe
what the watcher does when reporting fails.

## `done` test limitation
When the watcher reports `idle` after a completed turn, herdr should render this
as `done`. This cannot be tested with the herdr-stub alone (the stub is
text-based and doesn't simulate herdr's UI state machine). Manual verification
with a real herdr instance is required.
