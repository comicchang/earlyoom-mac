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
| `names` | Additional exact process names to suppress, case-insensitively. | macOS safety/session names in the sample |
| `bundle_ids` | Additional exact `CFBundleIdentifier` values to suppress. | empty |
| `extra_uids` | Additional numeric UIDs to suppress. | empty |

The mandatory baseline is always unioned with `names`, even if a local file omits it. It includes `launchd`/PID 1, `kernel_task`, `WindowServer`, `loginwindow`, `mDNSResponder`, `securityd`, `syspolicyd`, `coreaudiod`, `sshd`, `sshd-session`, common terminal emulators, `tmux`, and `screen`. These targets are protected because terminating them can break the OS, the graphical login, networking/security/audio, or the user's current SSH/terminal work. Current UID/session protection is also enabled by default, so a newly started instance reports but does not target the operator's work.

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

Run:

```sh
swift test
```

## Prior art and license

Prior-art conclusions and links are in [`docs/RESEARCH.md`](docs/RESEARCH.md). Existing MIT projects were considered but none met the complete safety/metric/configuration requirements; Linux OOM daemons are not portable to Darwin. The project uses the **MIT license** because it is permissive, familiar to Swift/systems-tool users, and compatible with an independently written implementation. It does not permit copying GPL-licensed Linux implementations; those remain reference-only. See [`LICENSE`](LICENSE).

## Contributing, security, and conduct

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), [`NOTICE`](NOTICE), and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Safety changes require tests that prove both the intended action and the no-action boundary.
