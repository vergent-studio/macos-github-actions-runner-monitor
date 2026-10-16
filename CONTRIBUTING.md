# Contributing to Runner Monitor

Thank you for contributing to **Runner Monitor**! This document outlines how to set up your development environment, run tests, and submit changes.

---

## Development Requirements

- macOS 14.6 or newer
- Xcode 16.0 or newer (Swift 6 language mode enabled)

---

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/vergent-studio/macos-github-actions-runner-monitor.git
   cd macos-github-actions-runner-monitor
   ```
2. Open `RunnerMonitor.xcodeproj` in Xcode or run tests from the terminal:
   ```bash
   xcodebuild -project RunnerMonitor.xcodeproj -scheme RunnerMonitor -destination 'platform=macOS' test
   ```

---

## Architectural & Code Guidelines

1. **Keep Monitoring Read-Only**:
   - The monitoring loop (`RunnerDiscovery`, `LaunchdStatusReader`, `RunnerLogReader`, `RunnerStatusResolver`) must remain strictly read-only. Never start, stop, or mutate runner services from the background polling loop.
2. **Evidence-Based Status Resolution**:
   - Every status transition in `RunnerStatusResolver` must be backed by concrete evidence from `launchd` and the current runner session log. Prefer `.unknown` with a clear human-readable explanation over guessing.
3. **No Hard-Coded Machine or Account Details**:
   - Never hard-code user home paths, GitHub organization names, repository names, or runner agent names in production code or tests. Use `FileManager.default.homeDirectoryForCurrentUser` or configurable paths.
4. **No Dynamic Shell Execution**:
   - Never invoke `sh -c` or `bash -c` with interpolated paths. Use `Foundation.Process` with fixed executable URLs and explicit argument arrays.
5. **Bounded File I/O Off the Main Thread**:
   - All filesystem and `launchctl` inspection must run off `@MainActor`, reading only bounded log tails (`RunnerLogReader`).

---

## Pull Request Checklist

- [ ] Code compiles cleanly with zero warnings under Swift 6 (`SWIFT_VERSION = 6.0`).
- [ ] All unit tests in `RunnerMonitorTests` pass (`xcodebuild ... test`).
- [ ] New status resolution or parser behavior is covered by deterministic unit tests using temporary fixtures.
- [ ] No machine-specific paths, secrets, or tokens are included in commits or test fixtures.

---

## License

By contributing to Runner Monitor, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
