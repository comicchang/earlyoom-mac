# earlyoom-mac

A native macOS memory-pressure watchdog inspired by the workload-ranking idea in Linux [earlyoom](https://github.com/rfjakob/earlyoom). It measures process **physical footprint** (`ri_phys_footprint`), not RSS, and can report the largest eligible workload before memory pressure becomes a system-wide failure.

> **Safety first:** the default configuration is **report-only**. It does not send signals, request app termination, register launchd, or enable itself at login.

## Why this exists

On macOS, RSS can dramatically under-report a process whose pages have been compressed or swapped. A process can therefore look tiny in RSS while retaining a damaging physical footprint. The daemon samples `proc_pid_rusage` and prints footprint and RSS side by side; only footprint participates in ranking.

This is a clean-room macOS implementation, not a Darwin port of Linux earlyoom. See [`docs/RESEARCH.md`](docs/RESEARCH.md) for the prior-art comparison and the reason no existing project is used directly or forked.

## Requirements

- macOS 13 or newer (Darwin `libproc`, Mach VM statistics, and AppKit APIs).
- Swift 6 toolchain / Xcode Command Line Tools.
- No Python, Homebrew, kernel extension, network service, or external dependency is required.
- Reading every process or signalling another user may require the permissions of the account running the program. The program does not elevate privileges itself.

## Build and run without installing a service

All commands below run in the checkout and leave system configuration untouched:

```sh
swift build -c release
swift test
swift run earlyoom-mac --print-default-config
swift run earlyoom-mac --once
swift run earlyoom-mac --config /path/to/earlyoom-mac.conf --once
```

With no `--config`, the executable constructs the same safe report-only configuration shipped in `config/earlyoom-mac.conf`. `--once` performs one sample; omitting it keeps sampling at the configured interval. The command does not install a launchd plist. If you later want a service, create and review that integration yourself; it is intentionally outside this project.

### Manual user-local installation (optional)

This project intentionally has no installer or launchd registration. To place a reviewed executable in a user-owned directory:

```sh
swift build -c release
mkdir -p "$HOME/.local/bin" "$HOME/.config"
cp "$(swift build -c release --show-bin-path)/earlyoom-mac" "$HOME/.local/bin/earlyoom-mac"
cp config/earlyoom-mac.conf "$HOME/.config/earlyoom-mac.conf"
"$HOME/.local/bin/earlyoom-mac" --config "$HOME/.config/earlyoom-mac.conf" --once
```

The copy remains report-only. Adding it to a service manager, changing permissions, or enabling enforcement is an operator decision and is not performed by this repository.

The report includes:

- pressure level and reclaimable available-memory fraction;
- `phys_footprint` for each candidate group;
- RSS for comparison only;
- footprint/RSS divergence;
- badness score and proposed action;
- suppression reason where the target is protected.

## Configuration

The file is a readable INI-style declaration with the earlyoom-like `[earlyoom]`, `[check]`, `[action]`, and `[suppression]` sections. Unknown keys, unknown sections, malformed values, and a metric other than `phys_footprint` are rejected. Byte suffixes are binary (`MiB`, `GiB`) unless explicitly written as decimal (`MB`, `GB`); durations accept `ms`, `s`, or `m`; percentages accept `20%` or a fraction such as `0.20`.

### `[earlyoom]`

| Key | Meaning | Safe starter value |
| --- | --- | --- |
| `enabled` | Master permission for any enforcement. Must be `true` before an action can execute. | `false` |
| `report_only` | Second independent no-signal gate. When `true`, plans are logged but never executed. | `true` |
| `interval` | Time between samples in daemon mode. Must be greater than zero. | `5s` |
| `grace_period` | Time after TERM / graceful app quit before force escalation. | `10s` |

### `[check]`

| Key | Meaning | Safe starter value |
| --- | --- | --- |
| `metric` | Process metric for ranking. Only `phys_footprint` is accepted. | `phys_footprint` |
| `warn_available` | At or below this available fraction, report pressure and candidates. | `20%` |
| `terminate_available` | At or below this fraction, eligible enforcement plans may be produced. | `10%` |
| `kill_available` | At or below this fraction, the final pressure level is reported and configured GUI escalation may proceed. | `5%` |
| `minimum_candidate` | Ignore groups below this physical footprint. | `64MiB` |
| `criticality` | Optional comma-separated exact process-name weights such as `python3:1.5,node:0.8`; missing names use `1.0`. The weight multiplies physical-footprint badness. | empty |

Thresholds must satisfy `warn_available > terminate_available > kill_available`, and each must be between 0 and 100 percent. `criticality` weights must be positive finite numbers. The daemon uses free + inactive + purgeable pages as available; compressor pages remain part of physical demand.

### `[action]`

| Key | Meaning | Safe starter value |
| --- | --- | --- |
| `gui_escalation` | GUI action policy: `never`, `graceful_then_force`, `force_application`, or `process_group`. | `never` |
| `allow_process_group` | Permit TERM→KILL of a non-GUI process group or a GUI group when explicitly selected. | `false` |

A GUI app is identified by the executable's containing `.app` bundle and a non-empty `CFBundleIdentifier`, not by a display-name substring. See [`docs/DESIGN.md`](docs/DESIGN.md) for the complete decision table. Arbitrary thread killing is never performed.

`gui_escalation = process_group` requires `allow_process_group = true`; the parser rejects that mismatch at startup instead of silently downgrading it. When enforcement is enabled but process-group termination remains disabled, a non-GUI group with multiple members is reported as no-action: selecting one `.singleProcess` member would leave the multi-process workload running and would be misleading.

### `[suppression]`

| Key | Meaning | Safe starter value |
| --- | --- | --- |
| `protect_current_user` | Protect every process with the daemon's current UID. | `true` |
| `protect_current_session` | Protect every process in the daemon's current login session. | `true` |
| `protect_ancestors` | Protect the daemon's ancestor/descendant chain. | `true` |
| `protect_process_groups` | Protect any process group containing an intrinsically protected member. | `true` |
| `names` | Additional exact process names to suppress, case-insensitively. | the full mandatory macOS safety/session baseline (see below) |
| `bundle_ids` | Additional exact `CFBundleIdentifier` values to suppress. | empty |
| `extra_uids` | Additional numeric UIDs to suppress. | empty |

The mandatory baseline is always unioned with `names`, even if a local file omits it. It includes `launchd`/PID 1, `kernel_task`, `WindowServer`, `loginwindow`, `mDNSResponder`, `securityd`, `syspolicyd`, `coreaudiod`, `sshd`, `sshd-session`, common terminal emulators (`Terminal`, `iTerm2`, `Alacritty`, `kitty`, `WezTerm`, `Ghostty`), `tmux`, `screen`, and the additional desktop/session infrastructure names `notifyd`, `opendirectoryd`, `configd`, `runningboardd`, `distnoted`. These targets are protected because terminating them can break the OS, the graphical login, networking/security/audio, or the user's current SSH/terminal work. [`docs/DESIGN.md`](docs/DESIGN.md) gives the reason for each name. Current UID/session protection is also enabled by default, so a newly started instance reports but does not target the operator's work.

## How to deliberately enable enforcement (do not do this blindly)

The repository never enables this for you. A reviewed operator can make a private copy of the sample configuration and change **both** gates:

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

Copying this snippet means opting into termination for eligible processes: current-user and current-session protection are disabled, so ordinary user processes (including large agent, browser, VM, compiler, and terminal-adjacent workloads not covered by the mandatory names) enter the candidate set. Mandatory system/session names remain protected, and a multi-process group is still not terminated unless `allow_process_group = true` is deliberately added.

Before arming it:

1. Run the unmodified file for a full observation period.
2. Review the footprint/RSS columns and suppression reasons.
3. Add exact application bundle IDs that must never be selected.
4. Keep GUI escalation at `never` until you understand the workload; use `graceful_then_force` only when losing unsaved work is acceptable.
5. Run `--once` with the private file and review the proposed plans.
6. Start a manually supervised foreground process first. This project does not create or load launchd services.

`force_application` and `process_group` are destructive. A process-group action can terminate a shell and all of its children. No setting makes arbitrary thread termination safe, so the implementation never offers it.

## Action policy at a glance

- **Normal/warn:** report only.
- **Non-GUI candidate:** a singleton receives TERM; after the grace period a surviving process can receive KILL only in explicit enforcement mode. A multi-member process group is report-only unless `allow_process_group = true`, because killing one representative would leave the workload running.
- **Verified GUI app:** request a normal app quit first; only the selected GUI escalation permits force termination.
- **Protected target / ambiguous identity:** never act.
- **Thread-level action:** never act.

Every plan is produced after suppression and identity checks. The executor rejects report-only/protected plans independently of the planner.

## Behavior boundaries and risks

- This is a polling watchdog, not a hard memory cap. A process can allocate between samples.
- macOS permission failures can make another user's footprint unavailable; the daemon reports what it can and does not guess.
- If run as root without a reliable console-session identity, all non-root processes are suppressed rather than guessed into a user's session. Review session attribution separately before considering root enforcement.
- A GUI force escalation can lose unsaved data. A graceful quit may block on a save dialog or Automation permission.
- A process can exit or a PID can be reused after sampling. `ESRCH` is skipped; the program does not blindly retry a new process with the same number.
- App bundle grouping is reliable when `proc_pidpath` points inside a readable `.app` with a valid `Info.plist`. Bundle-less or relocated helpers are kept as process/process-group candidates rather than guessed into an app.
- Inactive/purgeable memory is treated as reclaimable; compressed memory is not. This is an explicit policy approximation and can differ from a future macOS pressure implementation.
- No caches are purged and no swap settings are changed.

### Known gaps in this release

These are real, currently unfixed limitations. They are listed here so a reader cannot
mistake the feature list above for coverage that does not exist. Each one states the
configuration that causes it, because in every case the default configuration is on the
safe-but-limited side.

1. **The defaults protect the very processes you probably want gone.** `protect_current_user = true` (the default) suppresses *every* process owned by the daemon's UID, not just the daemon's own tree. The runaway workload that motivates a memory-pressure watchdog — an agent kernel, a browser, a VM, a build — normally runs as that same user, so under the shipped configuration it is reported and never acted on. Reaching it requires setting `protect_current_user = false`, which also disarms the guard that keeps the watchdog from targeting the operator's own session. This is a deliberate trade: the safe default cannot distinguish "my important work" from "my runaway work", so it protects both.
2. **GUI applications can never be acted on under the default policy.** `gui_escalation = never` (the default) maps every verified app bundle to `reportOnly` in `CandidatePlanner.actionSafety`, so even with both enable gates set to their enforcement values, a macOS `.app` is reported and left running. The escalation ladder (`graceful_then_force`, `force_application`, `process_group`) exists and is tested at the planning level, but it is inert until an operator opts in — and each rung is destructive in a different way, which is exactly why none of them is the default.
3. **A workload with more than one process is refused entirely, not handled piecemeal.** When `allow_process_group = false` (the default) and a candidate group contains more than one member, the planner returns `reportOnly` for the *whole group* rather than terminating one member. It does **not** fall back to per-process termination of the largest member. The practical consequence is asymmetric and worth stating plainly: a genuinely single-process hog — one VM process, one compiler process, one runaway daemon — remains eligible under the default settings, while a multi-process workload (a browser plus its helpers, a worker pool, a build system fanning out) is never eligible no matter how large it grows, until `allow_process_group = true` is set. Members are grouped *after* the `minimum_candidate` filter, so a workload whose helpers each sit below `64MiB` can still collapse into a single-member group and stay eligible — it is the number of members above that threshold, not the raw process count, that decides. See [`docs/DESIGN.md`](docs/DESIGN.md) for why picking a representative was rejected rather than merely deprioritized.
4. **The code that actually sends signals has no test coverage.** `DarwinActionExecutor` — the `SIGTERM`/`SIGKILL` delivery, the `NSRunningApplication` graceful-then-force path, the process-group gate, and the PID-reuse re-verification — is excluded from the test target. The planner, the parser, the suppression policy, and the daemon seam are covered; the executor is not. Every safety claim about *which* action is selected is therefore regression-tested, while every claim about *how* it is delivered is currently argued rather than tested. See the mutation evidence in [`docs/DECISIONS.md`](docs/DECISIONS.md).
5. **Test discrimination is good on selection logic and absent on delivery logic.** Spot mutation checks confirm the suite fails when ranking is switched from `phys_footprint` to RSS, and when the mandatory suppression names stop being unioned. The same checks show that disabling the executor's PID-reuse guard entirely leaves the suite green. The suite is a real guardrail for *policy*, and not one for *mechanics*.

None of these are hidden behind configuration: in every case the tool prints the reason it declined to act (`action=reportOnly` / `action=protectedTarget` plus a `reason=` string) rather than staying silent.

See [`docs/DESIGN.md`](docs/DESIGN.md) for architecture, safety boundaries, GUI identity details, and known limitations.

## Testing

The test target covers:

- parser fail-closed behavior and safe defaults;
- required macOS infrastructure/session suppression;
- current-user/current-session protection;
- bundle ID resolution from an app fixture's `Info.plist`;
- GUI graceful/force/process-group decision mapping;
- a regression where a process has **19.84 GiB footprint and 7.8 MiB RSS**—ranking by RSS would select the wrong victim;
- a daemon smoke seam proving report-only mode calls no action executor.

It deliberately does **not** cover:

- exact pressure-level boundaries (`available` *exactly equal to* a threshold, rather than just below it);
- anything inside `DarwinActionExecutor`.

Those two are gaps, not coverage. The suite is a guardrail for **policy** — what gets
selected — and not for **mechanics** — how a signal is delivered. Mutation evidence for
both claims is recorded in [`docs/DECISIONS.md`](docs/DECISIONS.md).

Run:

```sh
swift test
```

## Prior art and license

Prior-art conclusions and links are in [`docs/RESEARCH.md`](docs/RESEARCH.md). Existing MIT projects were considered but none met the complete safety/metric/configuration requirements; Linux OOM daemons are not portable to Darwin. The project uses the **MIT license** because it is permissive, familiar to Swift/systems-tool users, and compatible with an independently written implementation. It does not permit copying GPL-licensed Linux implementations; those remain reference-only. See [`LICENSE`](LICENSE).

## Contributing, security, and conduct

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), [`NOTICE`](NOTICE), and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Safety changes require tests that prove both the intended action and the no-action boundary.

## Documentation

| Document | What it answers |
| --- | --- |
| [`docs/DESIGN.md`](docs/DESIGN.md) | How the daemon is structured, the full GUI decision table, the suppression rationale, and the complete list of known limitations. |
| [`docs/RESEARCH.md`](docs/RESEARCH.md) | Which prior art was evaluated, what its license and data sources were, and why this is a clean-room implementation rather than a fork. |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Why each major design choice was made, which alternatives were rejected and at what cost, and the verification evidence (config probes, behavioural probes, mutation checks) behind the current claims. |
