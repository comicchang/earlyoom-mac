# Design, trade-offs, and known limitations

## Goals and non-goals

The daemon is a pressure-triggered safety valve for a desktop Mac. It samples every process, measures physical ownership, ranks eligible workload units, and reports or performs a deliberately staged action. The default is **report-only** and cannot send a signal.

It is not a kernel OOM replacement, a memory “cleaner,” a hard per-process memory limit, or an automatic launchd installer. It does not register services, alter system configuration, or start at boot.

## Architecture

```text
DarwinMemorySampler ─┐
                     ├─ EarlyoomDaemon ─ CandidatePlanner ─ ActionExecutor
DarwinProcessSampler ┘         │                 │               ├─ DryRun (default)
                               │                 │               └─ Darwin signals/AppKit (explicit)
                               └─ report (phys_footprint + RSS side by side)
```

- `DarwinProcessSampler` uses `libproc` (`proc_listallpids`, `proc_pidinfo`) and `proc_pid_rusage(..., RUSAGE_INFO_V4, ...)`. The decision metric is `ri_phys_footprint`; RSS is displayed only as a diagnostic comparison.
- `DarwinMemorySampler` reads `hw.memsize`, `host_statistics64`, and `vm.swapusage`. Available memory is the reclaimable free + inactive + purgeable pool; compressor pages are **not** counted as free.
- `CandidatePlanner` applies suppression before ranking and aggregates a GUI application's helpers by bundle identity. Non-GUI processes are grouped by process group when a valid PGID exists.
- `ActionExecutor` is an injectable seam. The CLI selects `DryRunActionExecutor` unless the configuration explicitly sets both `enabled = true` and `report_only = false`.

## Metric and badness

For a group `g`:

```text
badness(g) = min(1, sum(ri_phys_footprint of members) / physical_memory * criticality_weight(g))
```

`criticality_weight` is an optional exact process-name multiplier from `[check] criticality`; it defaults to `1.0` and is looked up using the group's largest-footprint representative name. This preserves earlyoom's “usage × importance” shape without pretending Darwin exposes Linux `oom_score_adj`. Groups are sorted descending by this value, with PID as a deterministic tie-breaker. No RSS value participates in ranking.


The regression test uses a footprint of 19.84 GiB and RSS of 7.8 MiB. A ranking implementation that accidentally returns to RSS would select a different process and fails the test.

## Pressure levels and configuration

Thresholds are declared in the INI file, not command-line-only constants:

- `warn_available`: report pressure and candidates.
- `terminate_available`: eligible non-GUI processes may receive the configured action when enforcement is explicitly enabled.
- `kill_available`: the same planner enters the final escalation state; GUI policy still controls whether it may force terminate.

`interval`, `grace_period`, `minimum_candidate`, GUI escalation, and suppression lists are all configurable. Unknown sections/keys, invalid metrics, and incompatible action pairs fail closed with a parse error; in particular, `gui_escalation = process_group` requires `allow_process_group = true` and never silently downgrades. `metric` must be `phys_footprint`; selecting RSS is rejected.

The shipped `config/earlyoom-mac.conf` is safe and report-only. Supplying no config also uses the same safe mode.

## Suppression and allow-list semantics

The suppression list is an **allow-list of targets that may never be selected**, not a deny-list of known bad targets. The mandatory names are always unioned into the configured list, so deleting them from a local file cannot remove the baseline safety boundary:

| Target | Why it is protected |
| --- | --- |
| `launchd` / PID 1 | The process supervisor and ancestor of most jobs; killing it can destabilize or reboot the user space. |
| `kernel_task` | Kernel/system accounting and thermal-management task; it is not a valid user victim. |
| `WindowServer` | Owns the graphical display and compositing; killing it destroys the current desktop session. |
| `loginwindow` | Owns login/session lifecycle; termination can log out or strand the desktop. |
| `mDNSResponder` | System name-resolution/discovery service; its loss breaks networking for unrelated work. |
| `securityd` | Keychain/security services; killing it can strand credentials and security operations. |
| `syspolicyd` | Code-signing/Gatekeeper policy service; it is system infrastructure, not a workload. |
| `coreaudiod` | System audio service; restarting it can destroy active audio sessions. |
| `sshd` / `sshd-session` | The SSH transport and current remote work channel; killing it disconnects the operator and can lose the shell's work. |
| `Terminal`, `iTerm2`, `Alacritty`, `kitty`, `WezTerm`, `Ghostty` | Terminal UI owns visible work and unsaved command context. |
| `tmux`, `screen` | Session multiplexers own durable shell panes and agent jobs; killing one destroys the work scene even if children survive. |
| `notifyd`, `opendirectoryd`, `configd`, `runningboardd`, `distnoted` | Additional desktop/session/system infrastructure with broad blast radius. |

The policy also protects by default:

- the daemon's own PID;
- PID 0/1;
- the current user ID;
- the current login session ID obtained with `getsid`;
- the daemon's ancestor/descendant chain;
- any process group containing an intrinsically protected member.

These defaults mean a newly installed instance will normally report current-user applications but will not act on them. An operator who intentionally arms enforcement must review a dry-run report and explicitly set `protect_current_user = false` and `protect_current_session = false`; the mandatory names remain protected.

For a deliberately supervised foreground run, copy this fragment into a private configuration only after reviewing report-only output:

```ini
[earlyoom]
enabled = true
report_only = false

[action]
gui_escalation = graceful_then_force
allow_process_group = false

[suppression]
protect_current_user = false
protect_current_session = false
protect_ancestors = true
protect_process_groups = true
```

This explicitly puts ordinary current-user/session processes into the eligible set, including large agent, browser, VM, and compiler workloads not covered by mandatory names. It does **not** enable process-group termination; adding `allow_process_group = true` is a separate destructive decision, and without it multi-member non-GUI groups remain report-only because killing one member is not a meaningful workload action.

When running as UID 0 without a reliable console-session identity, the policy conservatively suppresses every non-root process. This prevents a manually installed root service from guessing which user's GUI/SSH workload is current; it also means operators must run the foreground report as the user or add a separately reviewed session-identity integration before attempting root enforcement.

## GUI identity and grouping

For each PID, the sampler obtains the resolved executable path with `proc_pidpath`. `BundleIdentityResolver`:

1. finds the containing `.app` component in the path;
2. opens that bundle's `Info.plist` through `Bundle(path:)`;
3. requires a non-empty `CFBundleIdentifier`;
4. records both the bundle identifier and canonical app path.

The grouping key is `bundle identifier + canonical app path`, so two versions or copies of an application are not merged merely because their display names match. Reparented helpers still group when they share the same containing bundle. The fixture test creates an `.app` and verifies the identifier from `Info.plist`; process names alone are never treated as proof of app identity.

This is stronger than a name heuristic but not omniscient: a helper launched outside its bundle, an executable with a missing/unreadable `Info.plist`, or a process that changes its path before sampling is represented as a non-GUI process. Such a process is not silently inferred to be an app.

## GUI action decision table

The planner emits a plan; only the explicit enforcement mode can execute it.

| Condition | Action | Rationale / boundary |
| --- | --- | --- |
| Normal or warning pressure | Report only | No termination is justified. |
| Candidate is protected by the suppression policy | Never act | This is checked during planning and the executor refuses protected/report-only plans. |
| Non-GUI singleton, enforcement enabled, `allow_process_group = false` | Send `SIGTERM` to one PID; after `grace_period`, `SIGKILL` only if it is still alive | The smallest unit; used for ordinary single-process CLI/workers. |
| Non-GUI process group with multiple members and `allow_process_group = false` | Report only | Killing one `.singleProcess` representative would leave the multi-process workload running, so the planner refuses the misleading action. |
| GUI bundle identified, `gui_escalation = graceful_then_force` | Call `NSRunningApplication.terminate()` for the matching app; after grace, call `forceTerminate()` only for survivors | Gives the app an opportunity to save/close. Matching uses bundle ID and the sampled PID/path, not a display-name substring. |
| GUI bundle identified, `gui_escalation = force_application` | Call `NSRunningApplication.forceTerminate()` for the verified bundle instance; after grace, KILL only still-live sampled members | Explicitly destructive; disabled by default. |
| GUI bundle identified, `gui_escalation = process_group` and `allow_process_group = true` | TERM then KILL the PGID only after group safety checks | Highest blast radius; the policy rejects groups containing protected members. |
| Arbitrary GUI helper or unknown app identity | Do not kill a single helper by heuristic | A helper may own unsaved state or be part of a larger app. Use whole-app graceful termination after identity is verified. |
| Thread-only termination | **Never implemented** | There is no safe external, public “kill this GUI worker thread” contract. `pthread_kill`/Mach thread actions cannot establish ownership or save state; using them would make the safety claim false. |

The implementation does not use AppleScript or a display-name match for quitting. `NSRunningApplication` is used only after bundle identity resolution, and the force step is a separate explicit policy value.

## Safety boundaries

- No action occurs unless `enabled = true` **and** `report_only = false`.
- The default executor is dry-run; the CLI chooses the signal/AppKit executor only after both switches are true.
- PID values are checked for `> 1` before direct signalling. PID 1 and the daemon are never candidates.
- Unknown config keys, invalid thresholds, and a non-`phys_footprint` metric fail closed.
- A process disappearing between sample and signal is treated as `ESRCH`, not as a reason to reuse a PID.
- Enforcement requires the permissions macOS grants the process; failure to signal is reported rather than retried in a loop.
- No launchd plist is installed or registered by this repository.
- The daemon does not purge caches, rewrite swap settings, or claim that disk space is RAM.

## Known limitations and trade-offs

1. **Sampling race:** a process can exit after enumeration. The sampler records Darwin's process start timestamp and the signal executor re-verifies it immediately before TERM/KILL; if the timestamp is unavailable or changed, it skips the action. A process can still change state after that check, so this is a race reduction, not a kernel transaction.
2. **Permissions:** a normal user may not read every other user's footprint or signal it. Run as a deliberately reviewed service account/root only if the operator accepts that larger authority boundary.
3. **Available memory is a policy approximation:** inactive/purgeable pages are treated as reclaimable, while compressor pages are not. macOS's private pressure model can change across releases.
4. **GUI lifecycle:** `NSRunningApplication.terminate()` depends on app responsiveness and Automation/session permissions. A force escalation can still lose unsaved data.
5. **No hard cap:** this is a polling watchdog. It cannot prevent a burst allocation between samples and cannot replace kernel memory management.
6. **Process groups are not cgroups:** a PGID can include a shell or foreground job. Group termination is opt-in and deliberately guarded.
7. **Identity edge cases:** bundle-less helpers and reparented processes without an app path remain singleton/process-group candidates rather than being guessed into an app.
8. **Architecture:** the package currently targets macOS and uses Darwin/AppKit APIs; Linux builds are intentionally unsupported rather than pretending the metric is portable.
