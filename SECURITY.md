# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

---

## Security Model & Design Principles

**Runner Monitor** is designed with a strict local-first, least-privilege security posture:

1. **Zero GitHub Credentials**:
   - Runner Monitor does not request, store, or transmit GitHub Personal Access Tokens (PATs), OAuth tokens, or runner registration tokens.
   - It makes zero network requests.
2. **Read-Only Monitoring Boundary**:
   - Normal monitoring reads only local runner metadata (`.runner`, `.service`, `svc.sh`), `launchd` status (`/bin/launchctl`), and local runner log files (`_diag/Runner_*.log`, `~/Library/Logs/<service>/stdout.log`, `stderr.log`).
   - `.credentials` and `.credentials_rsaparams` are never parsed, logged, or displayed; the app only checks whether `.credentials` exists on disk.
3. **No Arbitrary Script Execution**:
   - Runner Monitor never executes arbitrary scripts from runner directories during monitoring and never invokes commands through `bash -c` or `sh -c`.
   - Subprocesses use `Foundation.Process` with fixed system executable paths (`/bin/launchctl`) and structured argument arrays.
4. **Symlink Containment**:
   - `RunnerDiscovery` resolves symlinks canonically (`resolvingSymlinksInPath()`) and verifies that every discovered runner directory and metadata file remains inside the configured discovery root.
5. **Best-Effort Log Redaction**:
   - `SecretRedactor` masks recognizable GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), `Authorization: Bearer` headers, pipeline token URLs, and `--token` parameters before displaying or copying log lines, and local macOS notifications never include raw log snippets.

---

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, please report suspected vulnerabilities privately via [GitHub Security Advisories](https://github.com/vergent-studio/macos-github-actions-runner-monitor/security/advisories/new) on this repository.

When reporting, please include:
- A description of the issue and its potential impact
- Steps to reproduce or a proof-of-concept
- The macOS version and Runner Monitor version/commit tested

We will acknowledge receipt within 72 hours and work with you on verification and remediation before public disclosure.
