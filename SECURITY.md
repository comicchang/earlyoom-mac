# Security policy

## Reporting a vulnerability

Do not publish credentials, private process command lines, host identifiers, or a working kill recipe in a public issue.

**The channel is the repository's GitHub page: Security → Report a vulnerability.** That opens a
private advisory, readable only by the maintainers — it is the only private channel this project
has, because it publishes no security email address and no maintainer handle. Do not open a
public issue or a discussion for a vulnerability, and do not fall back to a draft advisory you
then abandon. Include:

- affected commit/version and macOS version;
- the smallest reproducible configuration or test;
- whether the issue can signal a protected target, bypass report-only mode, or misidentify an app;
- redacted logs and the permissions under which it ran.

Keep the report self-contained: an advisory that cannot be acted on without a round of questions
will have to be closed. Redact before you submit, not after.

## Scope

The highest-severity reports are safety-boundary failures: an unexpected signal while the two enable gates are not set, bypass of the mandatory suppression names, PID reuse leading to a signal to a different process, or bundle identity confusion that escalates a GUI app without an exact identity. Do not test enforcement against a real user or system process; use injected fixtures and a recording executor.
