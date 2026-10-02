# Prior-art research and selection

Research date: 2026-10-03. The project was compared with primary repository documentation/source, not with a claim that a similarly named program is a Darwin port.

## Decision

**Build a clean-room macOS implementation. Do not fork or directly deploy an existing project.** No candidate provides all of the required properties together: Darwin-native `phys_footprint` sampling, system-wide ranking, a declarative configuration file, an allow-list of session-critical targets, GUI-aware escalation, and a default that cannot signal. The MIT projects below are useful references; this implementation does not copy their source.

The selection is deliberately not “fork the closest README.” A fork would inherit a metric, process model, or lifecycle policy that is wrong for this product, and would make it harder to review the safety boundary independently.

## Candidates

| Project | What the primary source shows | License | Use/fork decision |
| --- | --- | --- | --- |
| [rfjakob/earlyoom](https://github.com/rfjakob/earlyoom) | Mature Linux C daemon. Its process code reads `/proc/<pid>/stat`; its memory code reads `/proc/meminfo`, including Linux `oom_score`/`oom_score_adj`. | MIT | **Reference only.** The badness/ranking and TERM-then-KILL ideas transfer, but the data sources do not exist on Darwin. No Darwin fork was found in the GitHub search performed for this project. |
| [facebookincubator/oomd](https://facebookincubator.github.io/oomd/) | Userspace OOM killer driven by Linux PSI and cgroup v2; supports cgroup-level actions. | GPL-2.0 (repository) | **Reference only.** Linux PSI/cgroup assumptions and license make it unsuitable as a code base for this MIT project. |
| [systemd/systemd](https://github.com/systemd/systemd) (`systemd-oomd`) | Linux/systemd service integrated with cgroups and pressure information. | GPL-2.0-or-later (project) | **Not portable; not a fork base.** |
| [fl4p/macos-oom-guard](https://github.com/fl4p/macos-oom-guard) | Small native Python daemon; README describes `proc_pid_rusage.ri_phys_footprint`, a pressure trigger, dry-run, and victim selection. Its configuration is environment variables and its safety policy is a hard-coded name denylist plus path rules. | MIT | **Closest reference, not direct use/fork.** The repository has very little review history and lacks a declarative, extensible allow-list and GUI escalation. |
| [intelogroup/caproom](https://github.com/intelogroup/caproom) | MIT Rust watchdog for a command/process tree; uses `proc_listallpids`, `proc_pidinfo`, and `ri_phys_footprint`, with TERM→grace→KILL. | MIT | **Reference only.** It intentionally watches a command subtree and is not a system-wide, GUI-aware OOM policy daemon. |
| [curlewlabs-com/macos-footprint-watchdog](https://github.com/curlewlabs-com/macos-footprint-watchdog) | MIT Python watchdog for one exact executable, with physical-footprint ceiling, re-verification, cooldown, and recovery checks. | MIT | **Reference only.** Its “refuse rather than guess” identity checks are valuable, but a one-target restart watchdog is not a system-wide victim selector. |
| [ganoliya/RAMWatcher](https://github.com/ganoliya/RAMWatcher) | Swift monitor/daemon that reads `ri_phys_footprint`, aggregates app helpers, resolves app bundles, and keeps a blocklist in the daemon. | MIT | **Reference only.** It is primarily a menu-bar monitor/control application and has a different privileged-service/install model; it does not provide this project's declarative staged policy. |
| [TomGranot/mac-memory-guard](https://github.com/TomGranot/mac-memory-guard) | Bash + launchd notifier. It aggregates app processes and asks the user to quit one app at a time; the README says RSS-based collection and no blanket kill. | MIT | **Reference only.** Good UX/graceful-quit idea, but RSS misses the failure mode this project exists to catch and it is interactive rather than a daemon policy engine. |
| [nkechr1s/macos-memory-pressure-daemon](https://github.com/nkechr1s/macos-memory-pressure-daemon) | Native C/Mach pressure responder with optional `task_set_phys_footprint_limit`, `SIGSTOP`, and `SIGKILL`, plus name/path heuristics. | MIT | **Reference only.** It is an experimental pressure/throttling design with a different policy and privilege model; it is not a drop-in safe system-wide allow-list daemon. |
| [kamalbuilds/ram-sentinel](https://github.com/kamalbuilds/ram-sentinel) | Rust notifier/menu-bar app that groups app processes and recommends closing them. | MIT | **Reference only.** It is primarily notification and app guidance; it does not satisfy the required physical-footprint enforcement policy. |

### Apple-branded `oomd`

The public Apple Open Source release index was searched for an Apple-published macOS userspace daemon named `oomd`; **none was found**: [Apple Open Source releases](https://opensource.apple.com/releases/). The public `oomd` result in this comparison is Facebook's Linux project, not an Apple/macOS implementation. macOS has system memory-pressure/memorystatus mechanisms, but no public Apple source/repository reviewed here provides a drop-in, configurable daemon with this project's safety contract. This is therefore not a direct-use or fork option; the implementation records the absence rather than guessing at private system behavior.

### Search result about an earlyoom Darwin port

A GitHub search for `earlyoom` together with `macOS`, `Darwin`, and `mac` found the Linux upstream and unrelated tools, but no maintained Darwin fork that implements this project's requirements. Therefore “fork the earlyoom macOS port” is not an available option. This document says **not found** rather than assigning an unverified repository to that role.

## What was reused as design evidence

1. **earlyoom:** early intervention, pressure thresholds, badness ordering, and a grace period between `SIGTERM` and `SIGKILL`.
2. **RAMWatcher / caproom / footprint-watchdog:** Darwin `proc_pid_rusage` usage, exact byte accounting, process-tree/bundle identity, and re-verification/cooldown as safety patterns.
3. **mac-memory-guard:** request a normal application quit before force termination.
4. **oomd:** the general principle that pressure-driven policy should operate on a meaningful workload unit rather than blindly killing one arbitrary PID; Darwin uses app bundle/process-group units instead of Linux cgroups.

The resulting implementation is independent Swift code. MIT attribution is limited to these documented inspirations; no existing source file is vendored.
