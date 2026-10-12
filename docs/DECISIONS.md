# Decisions, rejected alternatives, and verification record

This file is the project's memory of *how* it reached its current shape. It records the
options that were weighed and rejected, the cost each decision accepted, and the evidence
gathered during the release-readiness pass of 2026-10-03.

It deliberately keeps the paths that did **not** work. A reader who can see why a design
was rejected is far less likely to re-propose it, and a reader who can see which claims are
backed by a test and which are backed only by reasoning knows exactly how much to trust
each one. [`DESIGN.md`](DESIGN.md) describes what the system does; [`RESEARCH.md`](RESEARCH.md)
describes what already existed; this file describes *why*.

---

## 1. Decision log

### D-1. Clean-room implementation rather than a fork of an existing project

*Context.* Linux `earlyoom` solves a related problem and the workload-ranking idea is
genuinely good.

*Options.* (a) Port/fork the Linux daemon. (b) Fork an existing macOS project.
(c) Write an independent implementation.

*Decision.* (c).

*Why.* A fork inherits a metric and a lifecycle policy that are wrong here. Forking the
Linux daemon inherits `/proc/<pid>/stat` and `/proc/meminfo` data sources that do not exist
on Darwin at all; the parts that carry the safety properties are inseparable from the parts
that cannot be reused. Forking a macOS project inherits its privilege model and its
installation story, which would make the safety boundary materially harder to review
independently. Per-project analysis, licensing, and the "not found" results are in
[`RESEARCH.md`](RESEARCH.md).

*Cost accepted.* Reimplemented the ranking, the staged action, and the config format instead
of inheriting a battle-tested implementation.

### D-2. Rank by `ri_phys_footprint`, never by RSS

*Context.* This is the reason the project exists at all.

*Decision.* `proc_pid_rusage` with `RUSAGE_INFO_V4` and `ri_phys_footprint` is the decision
metric. RSS is collected and displayed **only** as a diagnostic column.

*Why.* On macOS a process whose pages have been compressed or swapped keeps a damaging
physical footprint while its RSS looks small. A resident-set-based watcher therefore both
mis-ranks the real offender and under-reports the pressure. The observed case that
motivated the project was a process holding ~19.84 GiB of footprint against ~7.8 MiB of
RSS — a ratio of roughly 2500x, which is not a rounding artifact of any metric. That
divergence is pinned by a regression test.

*Cost accepted.* `phys_footprint` is a heuristic maintained by the kernel rather than a
documented accounting contract, so it can change across macOS releases.

### D-3. Report-only by default, behind two independent gates

*Decision.* An action requires `enabled = true` **and** `report_only = false`. Both default
to the safe value (`false` / `true`).

*Why.* Two switches that must *both* be moved is not redundancy for its own sake. `enabled`
is the operator's statement of intent; `report_only` is the mode the tool is currently in.
A single switch cannot distinguish "I want this to be able to act" from "I want it to be
acting right now", and those are different questions. The executor also re-checks
`reportOnly` independently of the planner, so a planner bug cannot escalate a report-only
run.

*Rejected.* A single `enabled` flag. Rejected because the natural operator workflow —
build, observe for a week, then arm — needs a way to keep observing *after* arming.

### D-4. The suppression list is an allow-list unioned with a mandatory baseline

*Decision.* `SuppressionPolicy` always unions `SuppressionPolicy.defaultProtectedNames`
into whatever the configuration supplies. A local file cannot shrink the baseline.

*Why.* The failure mode of a denylist is that the next process someone forgets to list gets
killed. The mandatory names (`launchd`, `kernel_task`, `WindowServer`, `loginwindow`,
`mDNSResponder`, `securityd`, `syspolicyd`, `coreaudiod`, `sshd`/`sshd-session`, the
terminal emulators, `tmux`, `screen`, `notifyd`, `opendirectoryd`, `configd`,
`runningboardd`, `distnoted`) are precisely the ones nobody would think to list, because
nobody thinks of them as targets. Each is justified in the table in
[`DESIGN.md`](DESIGN.md). A test asserts the baseline survives an empty local list.

*Cost accepted.* A user who genuinely wants to reclaim memory from a protected name cannot
express that in configuration. This was considered and accepted: the same knob already
exists for the classes that *should* be adjustable (`protect_current_user`,
`protect_current_session`, `allow_process_group`).

### D-5. App identity from `CFBundleIdentifier`, never from a display-name substring

*Decision.* A process is a GUI application only when `proc_pidpath` resolves inside a
readable `.app` bundle with a non-empty `CFBundleIdentifier`.

*Why.* Helper processes across unrelated applications routinely share names
(`Helper`, `Web Content`, a generic `render` binary). Matching on a name substring would
let an unrelated helper inherit another application's blast radius. A bundle-less helper is
instead represented as an ordinary process candidate, which is a strictly more conservative
outcome.

*Rejected.* AppleScript / display-name quitting. Rejected as both unreliable and
identity-unsafe.

### D-6. Grouping key is `bundleIdentifier` + canonical app path

*Decision.* `application:<bundleID>:<appPath>`.

*Why.* Bundle ID alone merges a system copy and a developer build, which may be different
versions with different data. Path alone breaks when an app is relocated. The pair
separates them while still grouping reparented helpers that share a containing bundle.

### D-7. Refuse a multi-member group rather than terminate its largest member

*Decision.* When a candidate group has more than one member and `allow_process_group` is
`false`, the whole group is reported as `reportOnly`.

*Why.* Terminating one representative while its helpers survive would make the report
claim the workload was handled when it was not; the next round would re-report the same
workload under a different PID. For the workloads this tool targets, the helpers *are* the
leak.

*Cost accepted — and this is a genuine coverage gap.* Eligibility becomes size-independent
at "two members in a group": a single-process hog stays eligible under the defaults, while any
group with two or more members above `minimum_candidate` is ineligible no matter how large it
grows. (Grouping happens *after* the `minimum_candidate` filter, so helpers that each sit below
the threshold do not make a group multi-member.) This is recorded as
limitation 11 in [`DESIGN.md`](DESIGN.md) and gap 3 in the README rather than being
smoothed over, because the middle-ground behaviour (silently kill a representative) would
make the tool's output untrustworthy, which defeats its purpose. **Open:** see §4.

### D-8. Four-rung GUI escalation ladder, defaulting to the bottom rung

*Decision.* `never` (default) → `graceful_then_force` → `force_application` → `process_group`.

*Why each rung is separate.* They are not a difficulty gradient, they are four different
*kinds* of damage: a cooperative quit can lose unsaved work if the app blocks on a dialog;
`force_application` loses it unconditionally; `process_group` can take out a login session
or an SSH channel. Combining them behind one "aggressiveness" dial would hide that
difference. The `process_group` + `allow_process_group` pairing is rejected by the parser
rather than silently downgraded, so a typo cannot degrade into a weaker action than the
operator asked for.

*Cost accepted.* The default rung means the shipped configuration has no GUI enforcement
capability whatsoever.

### D-9. Thread-level termination is never implemented

*Decision.* Not offered in any configuration, at any rung.

*Why.* There is no public, supported contract for an external process to ask a GUI
application to "save and close this one worker thread". `pthread_kill` and Mach thread
actions cannot establish ownership or trigger a save. Offering the knob would make the
project's safety claim false at exactly the moment it mattered.

*Cost accepted.* Some real leaks (a single runaway thread inside a healthy app) are out of
reach by construction. Stating that is better than implying coverage.

### D-10. No launchd installer, no login item, no auto-start

*Decision.* The repository ships no plist and registers nothing.

*Why.* Installing a memory-pressure watchdog that can terminate processes is a
system-modifying action. Shipping it would mean the first `swift build` of a curious user
could arm a process killer, which contradicts the report-only default at the packaging
layer. Operators write their own reviewed integration.

### D-11. A root daemon refuses to guess a console session

*Decision.* When `getuid() == 0` and the target is non-root, suppress it
("user session identity unavailable to root daemon"), regardless of the
`protect_current_*` settings.

*Why.* Without a reliable console-session identity, a root daemon cannot know which user's
GUI or SSH session is "current". Suppressing everything non-root is fail-safe; guessing
would let a root install target an arbitrary logged-in user's work.

*Cost accepted.* A root install is effectively report-only until session attribution is
added deliberately.

### D-12. Available memory = free + inactive + purgeable, excluding the compressor

*Decision.* Documented as an explicit policy approximation, not as macOS memory pressure.

*Why.* Treating compressor pages as free would let the tool conclude there is no pressure
while the system is actively compressing; treating them as demand is the conservative
reading. macOS's private pressure model is not public and can change, so the tool claims
only what it can compute.

### D-13. Provenance: 语义移植自本机 memguard 硬化批次 (2026-10-08/09)

*Context.* A parallel daemon (`memguard`) developed by the same author on this machine underwent
multiple production hardening iterations following empirical 2026-10-08/09 memory exhaustion
incidents. Five operational semantics were proven necessary:
1. **Three-tier report cadence**: full report on initial run, four-level `PressureLevel` transition
   (`normal ↔ warn ↔ terminate ↔ kill`), or action execution; single-line heartbeat summary after
   `heartbeat` duration; zero output during steady state. This prevents 100+ MB/day log growth into
   launchd `StandardOutPath`.
2. **Fail-closed sampling and action failure handling**: transient sampling errors or signal-delivery
   failures (such as `EPERM`) in resident daemon mode log to stderr and continue to the next round
   instead of crashing the daemon into a launchd `KeepAlive` restart loop, while single-shot `--once`
   mode preserves throwing exit semantics.
3. **Enforce-mode single-instance mutex**: acquiring a non-blocking BSD `flock` (opened with `O_CLOEXEC`)
   on `~/.cache/earlyoom-mac/enforce.lock` before executing enforce mode, preventing two concurrent
   daemons from dispatching duplicate signals or leaking lock descriptors across child processes.
4. **Grace-period pressure re-evaluation**: checking global pressure before each ~1s grace-period sleep;
   if available memory is already at or drops to `kill_available`, `SIGKILL` is sent immediately without
   waiting out the full grace period (with surviving-member PID + start-time identity verification intact).
5. **Single-group-per-round action cap and fast resample**: acting on at most the single highest-badness
   eligible candidate group per sampling round (`CandidatePlanner` marks only the top eligible group
   actionable and `EarlyoomDaemon` breaks after the first `.executed` outcome), then resampling within
   `min(1s, interval)` before acting on any remaining candidates.
*Decision.* Port these five semantics into `earlyoom-mac` clean-room in Swift 6. No GPL code is
introduced; this port originates from the author's companion implementation.

*Why.* These mechanisms address real operational failures observed in long-running macOS deployments.

---

## 2. Consistency work done in this pass

Three artefacts describe the same defaults and had drifted apart. The drift was real and
is now resolved:

- the shipped `config/earlyoom-mac.conf`, the embedded
  `EarlyoomConfig.defaultConfigurationText` printed by `--print-default-config`, and the
  README's enumeration of the mandatory suppression names disagreed about five
  infrastructure names (`notifyd`, `opendirectoryd`, `configd`, `runningboardd`,
  `distnoted`). The code always protected all of them; only the documentation and the
  sample list were short. All three now name the full baseline, and the sample says where
  the authoritative list lives (`SuppressionPolicy.defaultProtectedNames`) so the next
  reader does not have to guess which copy is real.
- CI did not check that either configuration file actually parses. It now does, because the
  drift above was invisible to `swift test`.

---

## 3. Verification performed

All results below were produced by running the commands, not by reading the code.

### 3.1 Per-key configuration acceptance

Every key in the shipped sample was probed **individually** against the release binary via
`--config <file> --once`, plus the documented alternative value forms:

- 30 probes accepted, 1 rejected.
- The single rejection was `action.gui_escalation = process_group` **in isolation**, which
  correctly fails because it requires `allow_process_group = true`. Setting both together
  parses and yields `.processGroup` / `allowProcessGroupTermination = true`.
- `config/earlyoom-mac.conf` parses, and `--print-default-config` round-trips: the text the
  tool prints is itself a valid input to the tool.
- Confirmed accepted forms: percentages as `20%` or `0.20`; durations as `500ms`, `5s`,
  `5m`; sizes as `64MiB` (binary) and `64MB` (decimal); booleans as `true`/`yes`/`on`/`1`
  and `false`/`no`/`off`/`0`; `criticality = python3:1.5,node:0.8`.

### 3.2 Behavioural probes

Six throwaway tests (written, run, then deleted — they were probes, not committed tests)
confirmed the exact semantics claimed in the README and DESIGN:

| Claim | Observed |
| --- | --- |
| multi-member group, `allow_process_group = false` | one group, one plan, `reportOnly` — refused wholesale, no per-process fallback |
| single-process workload, `allow_process_group = false` | `singleProcess` — still eligible |
| multi-member group, `allow_process_group = true` | `processGroup` |
| verified GUI bundle, `gui_escalation = never`, enforcement on | `reportOnly`, reason "configured report-only or no applicable action" |
| 12 GiB runaway owned by the current UID | suppressed with reason "current user" |
| `gui_escalation = process_group` + `allow_process_group = true` | parses; both values as expected |

The first three rows are the empirical basis for D-7 and for the wording of the README's
gap 3. An earlier phrasing of that gap — that multi-process workloads are "handled
per-process" when `allow_process_group` is false — was **wrong** and was corrected against
this evidence before being written down.

### 3.3 Mutation spot checks

Each mutation was applied, the suite run, and the change reverted:

| Mutation | Result |
| --- | --- |
| badness computed from `residentBytes` instead of `physicalBytes` | **caught** — 2 tests fail |
| mandatory names no longer unioned into the configured list | **caught** — 1 test fails |
| `DarwinActionExecutor.isSameProcess` forced to return `true` (PID-reuse guard disabled) | **caught** — `gracePeriodPIDReuseGuard` and `processGroupPartialExitAndPIDReuseGuard` fail (originally **survived** in the 2026-10-03 pass before `5dd99bf` added injectable executor seams) |
| `EarlyoomDaemon` skipping `enforceLock?.acquire()` | **caught** — `enforceLockSingleInstanceMutex` fails on daemon-level contention |

While `5dd99bf` and subsequent hardening closed the seam gap for `.singleProcess` and `.processGroup`
signal delivery (including partial group exit escalation and PID-reuse degradation), the AppKit
`NSRunningApplication` GUI execution branches (`.gracefulApplication` and `.forceApplication`) still do
not have an injectable seam and remain tested only at the `CandidatePlanner` decision-table level.

---

## 4. Open items, in priority order

1. **Test `DarwinActionExecutor` GUI (`NSRunningApplication`) branches.** [Partially resolved 2026-10-12]
   Dependencies (`MemorySampling`, PID verifier, signal sender, sleeper) were made injectable in
   `DarwinActionExecutor`, and automated tests in `EarlyoomMacTests` now cover `.singleProcess` and
   `.processGroup` signal delivery, grace-period early `SIGKILL`, `grace_period = 0s`, sampling error
   fallback, and PID-reuse refusal without sending live OS signals. Extracting a protocol seam for
   `NSRunningApplication` to unit-test `.gracefulApplication` and `.forceApplication` delivery remains open.
2. **Decide what to do about the multi-member refusal (D-7).** Either document-only (current
   state), or add an explicit opt-in that terminates the *largest member* under a separate
   configuration key with a name that cannot be confused with whole-group termination.
   Silently narrowing the current refusal is not acceptable — it would reintroduce the
   misreporting D-7 was written to prevent.
3. **Pin the pressure-level boundaries.** A test with `available` exactly equal to each
   threshold would close limitation 13 at trivial cost.
4. **Re-check the mandatory-name list against current macOS.** The list was assembled from
   the failure modes each daemon causes. A future macOS release can add system services
   with the same blast radius; nothing in CI would notice.