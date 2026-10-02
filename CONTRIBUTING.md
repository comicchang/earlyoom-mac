# Contributing

Thanks for improving earlyoom-mac. This project can terminate processes, so safety and evidence take priority over feature breadth.

## Before opening a change

1. Read [`README.md`](README.md), [`docs/DESIGN.md`](docs/DESIGN.md), and [`docs/RESEARCH.md`](docs/RESEARCH.md).
2. Open an issue for policy changes or new enforcement behavior. Explain the failure mode, the affected macOS versions, and why report-only behavior is insufficient.
3. Keep examples and logs generic. Do not include usernames, hostnames, serial numbers, private repository names, or unredacted process command lines.

## Development

```sh
swift build
swift test
swift run earlyoom-mac --once
```

Do not register launchd jobs or run the signal executor while developing. Use the injected samplers and recording executor in tests. The normal CLI with no config is report-only.

## Test requirements

A change that affects selection, ranking, suppression, grouping, or action execution MUST include a deterministic test for the consumer-visible boundary. In particular:

- memory decisions MUST use `phys_footprint`, with RSS only a diagnostic value;
- GUI identity tests MUST use a bundle fixture and `Info.plist`, not only process names;
- safety changes MUST test a protected target and an eligible target;
- action tests MUST prove report-only mode does not call an executor;
- tests MUST NOT send signals to real user/system processes.

## Pull requests

Describe:

- the problem and the chosen safety boundary;
- macOS versions and permissions exercised;
- tests run and their output;
- whether the default behavior remains report-only;
- documentation/configuration changes.

Do not add a launchd installer, auto-start behavior, or a new privileged operation without a separate design review. Keep changes focused and avoid unrelated formatting churn.
