# Runner Monitor for macOS

**Runner Monitor** is a native macOS menu bar application (Swift 6 / SwiftUI) that monitors local self-hosted GitHub Actions runners (`~/actions-runners/runner-*`), displays real-time status and job execution activity, and provides bounded log inspection and `launchd` LaunchAgent supervision setup.

Licensed under the [Apache License 2.0](LICENSE).

---

## Features

- **Automatic Local Runner Discovery**: Scans `~/actions-runners/` (or any user-configured root directory) for `runner-*` installations and parses `.runner` (including UTF-8 BOM), `.service`, `svc.sh`, and `~/Library/LaunchAgents/<service>.plist`.
- **Evidence-Based 9-State Status Model**:
  - `Idle`, `Busy`, `Starting`, `Restarting`, `Stopped`, `Failed`, `Not installed`, `Not configured`, and `Unknown`.
  - Combines live `launchd` service state (`/bin/launchctl`), active runner diagnostic logs (`_diag/Runner_*.log`), and service wrapper logs (`~/Library/Logs/<service>/stdout.log` & `stderr.log`).
  - Protects against false positives (never reports `Idle` solely from a PID without `Listening for Jobs`; never reports `Busy` from a stale log of an older process; skips `configure`-only diagnostic logs).
- **Menu Bar Status Indicator**:
  - **Green** (`All Idle`): Every discovered runner is registered, running under `launchd`, and listening for jobs.
  - **Yellow** (`Busy`): At least one runner is actively executing a GitHub Actions workflow job (with live elapsed timer), and all others are healthy.
  - **Red** (`Degraded`): At least one runner is stopped, restarting, failed, or not installed.
  - **Gray** (`Unknown`): No runners discovered or status cannot be determined.
- **Bounded Log Viewer & Secret Redaction**:
  - Reads only bounded log tails (`FileHandle` seek + inode/size rotation tracking) to maintain near-zero idle CPU and low memory usage.
  - Supports text search, log level filtering (`INFO`, `WARN`, `ERR`), source filtering (`_diag`, `stdout`, `stderr`), clipboard copy, and quick reveal in Finder.
  - Automatically redacts recognizable GitHub tokens (`ghp_`, `ghs_`, `github_pat_`), `Bearer` credentials, and pipeline token URLs before displaying or copying logs.
- **Native macOS Supervision Setup (`launchd`)**:
  - Inspects and configures official GitHub Actions runner LaunchAgents (`~/Library/LaunchAgents/actions.runner.*.plist`) with `RunAtLoad = true`, `KeepAlive = true`, and `ThrottleInterval = 30` so runners start automatically on login and recover from unexpected crashes without custom daemon wrappers.
- **Local-First & Zero GitHub API Credentials**:
  - Operates 100% locally in read-only monitoring mode. Requires no GitHub Personal Access Tokens (PATs), OAuth apps, or network polling.

---

## System Requirements

- **macOS**: 14.6 (Sonoma) or newer (Apple Silicon or Intel)
- **Xcode**: 16.0+ with Swift 6 toolchain
- **GitHub Actions Runner**: Official macOS self-hosted runner installations under `~/actions-runners/runner-*` (or a custom directory)

---

## Project Structure

```text
RunnerMonitor.xcodeproj
Package.swift
RunnerMonitor/
  App/
    RunnerMonitorApp.swift      # MenuBarExtra entry point & status bar label
    AppState.swift              # Observable state, background polling & sleep/wake handling
  Models/
    RunnerStatus.swift          # 9-state runner status & 4-state aggregate status
    Runner.swift                # Runner registration, service config & job models
    RunnerEvent.swift           # Transition events & log entry models
  Services/
    RunnerDiscovery.swift       # Read-only filesystem & symlink-safe discovery
    LaunchdStatusReader.swift   # /bin/launchctl service inspection
    RunnerLogReader.swift       # Bounded tail reader with rotation/truncation support
    RunnerStatusResolver.swift  # Evidence-based status & event resolution
    SecretRedactor.swift        # Best-effort token & credential redaction
    NotificationManager.swift   # Local macOS user notifications
  Views/
    MenuBarView.swift           # Main popover dashboard & recent activity feed
    RunnerRow.swift             # Compact status row with live job timer
    RunnerDetailView.swift      # Detailed metadata, service health & Finder links
    LogViewer.swift             # Searchable, filterable bounded log viewer
    SettingsView.swift          # Root path, polling interval, notifications & setup UI
  Setup/
    ServiceSetupManager.swift   # Idempotent LaunchAgent supervision setup & rollback
  Resources/
    Info.plist                  # LSUIElement menu bar agent configuration
RunnerMonitorTests/
  RunnerMonitorTests.swift      # 23 unit tests covering all specification scenarios
```

---

## Building and Running

### Option 1: Build and Run in Xcode

1. Open `RunnerMonitor.xcodeproj` in Xcode:
   ```bash
   open RunnerMonitor.xcodeproj
   ```
2. Select the **RunnerMonitor** scheme and **My Mac** destination.
3. Press **Cmd+R** to build and run. The **Runner Monitor** icon appears in the macOS menu bar (`LSUIElement = true`, no Dock icon).

### Option 2: Build from the Command Line (`xcodebuild`)

```bash
xcodebuild \
  -project RunnerMonitor.xcodeproj \
  -scheme RunnerMonitor \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

To install the built app into `/Applications`:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/RunnerMonitor-*/Build/Products/Release/"Runner Monitor.app" /Applications/
open "/Applications/Runner Monitor.app"
```

### Running the Automated Test Suite

```bash
xcodebuild \
  -project RunnerMonitor.xcodeproj \
  -scheme RunnerMonitor \
  -destination 'platform=macOS' \
  test
```

---

## Automatic Recovery & `launchd` Supervision

Runner Monitor relies on macOS `launchd` (via the official GitHub Actions runner LaunchAgent in `~/Library/LaunchAgents/`) as the single supervisor for runner processes.

### Installing and Supervising a Runner Service

For each registered runner directory (e.g. `~/actions-runners/runner-1`):

1. Install the official LaunchAgent service:
   ```bash
   cd ~/actions-runners/runner-1
   ./svc.sh install
   ```
2. Configure `RunAtLoad`, `KeepAlive`, and `ThrottleInterval` (`30` seconds) either from **Runner Monitor → Settings → Service Supervision Setup → Configure & Start LaunchAgents…** or via `PlistBuddy`:
   ```bash
   PLIST_PATH=$(cat ~/actions-runners/runner-1/.service | tr -d '\r\n')
   /usr/libexec/PlistBuddy -c "Set :RunAtLoad true" "$PLIST_PATH" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST_PATH"
   /usr/libexec/PlistBuddy -c "Set :KeepAlive true" "$PLIST_PATH" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST_PATH"
   /usr/libexec/PlistBuddy -c "Set :ThrottleInterval 30" "$PLIST_PATH" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 30" "$PLIST_PATH"
   /usr/bin/plutil -lint "$PLIST_PATH"
   ./svc.sh start
   ```

### Uninstalling / Rolling Back Supervision

To stop and remove a runner's LaunchAgent service without deleting its GitHub registration:

```bash
cd ~/actions-runners/runner-1
./svc.sh stop
./svc.sh uninstall
```

Backups created by Runner Monitor before modifying any LaunchAgent property list are stored in:
`~/Library/Application Support/RunnerMonitor/Backups/<service-name>/`

To uninstall **Runner Monitor** itself:
1. Quit **Runner Monitor** from the menu bar popover.
2. Remove `/Applications/Runner Monitor.app`.
3. Optionally remove saved preferences:
   ```bash
   defaults delete studio.vergent.runnermonitor
   ```

---

## Security & Privacy

- **Read-Only Monitoring**: Normal monitoring never modifies runner files, `.credentials`, or service state.
- **No Shell Interpolation**: System inspection uses Foundation `Process` with fixed executable paths (`/bin/launchctl`) and structured argument arrays.
- **Symlink Containment**: Candidate runner directories and files are canonically resolved to prevent symlink traversal outside the configured root directory.
- **Redaction**: Recognizable tokens and credentials are redacted in displayed and copied logs.

See [SECURITY.md](SECURITY.md) for full details and vulnerability reporting instructions.

---

## License

Copyright 2026 Vergent Studio. Licensed under the [Apache License 2.0](LICENSE).
