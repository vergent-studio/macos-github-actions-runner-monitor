import Foundation
import Testing
@testable import RunnerMonitor

struct MockLaunchdStatusReader: LaunchdStatusReading {
    let snapshotsByService: [String: LaunchdServiceSnapshot]
    let defaultSnapshot: LaunchdServiceSnapshot?

    init(
        snapshotsByService: [String: LaunchdServiceSnapshot] = [:],
        defaultSnapshot: LaunchdServiceSnapshot? = nil
    ) {
        self.snapshotsByService = snapshotsByService
        self.defaultSnapshot = defaultSnapshot
    }

    func readStatus(for serviceName: String) -> LaunchdServiceSnapshot {
        if let snap = snapshotsByService[serviceName] {
            return snap
        }
        if let defaultSnapshot {
            return defaultSnapshot
        }
        return LaunchdServiceSnapshot(
            serviceName: serviceName,
            isLoaded: false,
            pid: nil,
            lastExitStatus: nil,
            runsCount: nil,
            stateDescription: "not loaded",
            querySucceeded: true
        )
    }
}

@Suite("Runner Monitor Specification Tests")
struct RunnerMonitorTests {
    // MARK: - Test Fixture Helpers

    private func makeTempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    private func createRunnerFixture(
        in rootURL: URL,
        dirName: String = "runner-1",
        agentName: String = "mac-runner-1",
        agentId: Int = 21,
        gitHubUrl: String = "https://github.com/example-org/example-repo",
        includeBOM: Bool = true,
        includeScripts: Bool = true,
        includeCredentials: Bool = true,
        includeServiceFile: Bool = true,
        includePlist: Bool = true,
        launchAgentsURL: URL,
        logsRootURL: URL,
        diagLogs: [(filename: String, content: String)] = [],
        stdoutContent: String? = nil
    ) throws -> (runnerDir: URL, serviceName: String, plistURL: URL) {
        let fm = FileManager.default
        let runnerDir = rootURL.appendingPathComponent(dirName, isDirectory: true)
        let binDir = runnerDir.appendingPathComponent("bin", isDirectory: true)
        let diagDir = runnerDir.appendingPathComponent("_diag", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: diagDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)

        let serviceName = "actions.runner.example-org-example-repo.\(agentName)"
        let plistURL = launchAgentsURL.appendingPathComponent("\(serviceName).plist")
        let svcLogDir = logsRootURL.appendingPathComponent(serviceName, isDirectory: true)
        try fm.createDirectory(at: svcLogDir, withIntermediateDirectories: true)

        if includeScripts {
            let scriptText = "#!/bin/bash\nexit 0\n"
            for name in ["config.sh", "run.sh", "runsvc.sh"] {
                let url = runnerDir.appendingPathComponent(name)
                try scriptText.write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            let binRunsvc = binDir.appendingPathComponent("runsvc.sh")
            try scriptText.write(to: binRunsvc, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binRunsvc.path)

            let svcSh = """
            #!/bin/bash
            SVC_NAME="\(serviceName)"
            """
            try svcSh.write(to: runnerDir.appendingPathComponent("svc.sh"), atomically: true, encoding: .utf8)
        }

        if includeCredentials {
            try "{}".write(to: runnerDir.appendingPathComponent(".credentials"), atomically: true, encoding: .utf8)
        }

        let runnerJSON = """
        {
          "agentId": \(agentId),
          "agentName": "\(agentName)",
          "poolId": 1,
          "poolName": "Default",
          "serverUrl": "https://pipelines.actions.githubusercontent.com/secretToken123",
          "gitHubUrl": "\(gitHubUrl)",
          "workFolder": "_work"
        }
        """
        var runnerData = Data()
        if includeBOM {
            runnerData.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        runnerData.append(Data(runnerJSON.utf8))
        try runnerData.write(to: runnerDir.appendingPathComponent(".runner"))

        if includeServiceFile {
            try (plistURL.path + "\n").write(to: runnerDir.appendingPathComponent(".service"), atomically: true, encoding: .utf8)
        }

        let stdoutURL = svcLogDir.appendingPathComponent("stdout.log")
        let stderrURL = svcLogDir.appendingPathComponent("stderr.log")
        if let stdoutContent {
            try stdoutContent.write(to: stdoutURL, atomically: true, encoding: .utf8)
        }

        if includePlist {
            let plistDict: [String: Any] = [
                "Label": serviceName,
                "ProgramArguments": [runnerDir.appendingPathComponent("runsvc.sh").path],
                "UserName": "testuser",
                "WorkingDirectory": runnerDir.path,
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 30,
                "StandardOutPath": stdoutURL.path,
                "StandardErrorPath": stderrURL.path,
                "EnvironmentVariables": ["ACTIONS_RUNNER_SVC": "1"],
                "ProcessType": "Interactive",
                "SessionCreate": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try data.write(to: plistURL)
        }

        for (index, diag) in diagLogs.enumerated() {
            let url = diagDir.appendingPathComponent(diag.filename)
            try diag.content.write(to: url, atomically: true, encoding: .utf8)
            let modDate = Date(timeIntervalSince1970: 1_760_000_000 + TimeInterval(index * 60))
            try fm.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        }

        return (runnerDir.resolvingSymlinksInPath(), serviceName, plistURL)
    }

    // MARK: - 1. Single runner discovery

    @Test("1. Single runner discovery")
    func singleRunnerDiscovery() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        _ = try createRunnerFixture(
            in: root,
            dirName: "runner-1",
            agentName: "alpha-runner-1",
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidates = discovery.discoverRunners(in: root)

        #expect(candidates.count == 1)
        #expect(candidates[0].registration?.agentName == "alpha-runner-1")
        #expect(candidates[0].registration?.repositoryDisplayName == "example-org/example-repo")
        #expect(candidates[0].hasValidBinaries == true)
        #expect(candidates[0].hasCredentials == true)
        #expect(candidates[0].serviceConfig?.isInstalled == true)
    }

    // MARK: - 2. Multiple runner discovery

    @Test("2. Multiple runner discovery")
    func multipleRunnerDiscovery() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        for i in 1...3 {
            _ = try createRunnerFixture(
                in: root,
                dirName: "runner-\(i)",
                agentName: "mac-runner-\(i)",
                agentId: 20 + i,
                launchAgentsURL: launchAgents,
                logsRootURL: logs
            )
        }

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidates = discovery.discoverRunners(in: root)

        #expect(candidates.count == 3)
        #expect(candidates.map { $0.registration?.agentName } == ["mac-runner-1", "mac-runner-2", "mac-runner-3"])
    }

    // MARK: - 3. Missing root directory

    @Test("3. Missing root directory")
    func missingRootDirectory() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let nonExistentRoot = temp.appendingPathComponent("does-not-exist")

        let discovery = RunnerDiscovery()
        let candidates = discovery.discoverRunners(in: nonExistentRoot)
        #expect(candidates.isEmpty)
        #expect(AggregateRunnerStatus.resolve(from: []) == .unknown)
    }

    // MARK: - 4. Empty root directory

    @Test("4. Empty root directory")
    func emptyRootDirectory() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("actions-runners")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let discovery = RunnerDiscovery()
        let candidates = discovery.discoverRunners(in: root)
        #expect(candidates.isEmpty)
    }

    // MARK: - 5. Malformed .runner file

    @Test("5. Malformed .runner file resolves to Not configured")
    func malformedRunnerFile() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )
        // Corrupt .runner with invalid JSON
        try "{ invalid json".write(to: fixture.runnerDir.appendingPathComponent(".runner"), atomically: true, encoding: .utf8)

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidates = discovery.discoverRunners(in: root)
        #expect(candidates.count == 1)

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidates[0],
            launchdSnapshot: nil,
            logSnapshot: RunnerLogSnapshot()
        ).runner

        #expect(resolved.status == .notConfigured)
        #expect(resolved.statusExplanation.contains("Malformed .runner"))
    }

    // MARK: - 6. Missing .service file

    @Test("6. Missing .service file resolves to Not installed")
    func missingServiceFile() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        _ = try createRunnerFixture(
            in: root,
            includeServiceFile: false,
            includePlist: false,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidates = discovery.discoverRunners(in: root)
        #expect(candidates.count == 1)

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidates[0],
            launchdSnapshot: nil,
            logSnapshot: RunnerLogSnapshot()
        ).runner

        #expect(resolved.status == .notInstalled)
    }

    // MARK: - 7. Missing LaunchAgent property list

    @Test("7. Missing LaunchAgent property list referenced by .service resolves to Failed")
    func missingLaunchAgentPlist() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        _ = try createRunnerFixture(
            in: root,
            includeServiceFile: true,
            includePlist: false,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidates = discovery.discoverRunners(in: root)
        #expect(candidates.count == 1)

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidates[0],
            launchdSnapshot: nil,
            logSnapshot: RunnerLogSnapshot()
        ).runner

        #expect(resolved.status == .failed)
        #expect(resolved.statusExplanation.contains("missing"))
    }

    // MARK: - 8. Running and idle runner

    @Test("8. Running and idle runner resolves to Idle")
    func runningAndIdleRunner() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let diagLog = """
        [2026-10-15 17:17:40Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:17:40Z INFO Listener] Version: 2.337.0
        [2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: 2026-10-15 17:17:42Z: Listening for Jobs
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-171740-utc.log", diagLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logReader = RunnerLogReader()
        let logSnap = logReader.readSnapshot(for: candidate)
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: 4821,
            lastExitStatus: 0,
            runsCount: 1,
            stateDescription: "running"
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(candidate: candidate, launchdSnapshot: launchdSnap, logSnapshot: logSnap).runner

        #expect(resolved.status == .idle)
        #expect(resolved.servicePID == 4821)
        #expect(resolved.runnerVersion == "2.337.0")
        #expect(AggregateRunnerStatus.resolve(from: [resolved]) == .allIdle)
    }

    // MARK: - 9. Running and busy runner

    @Test("9. Running and busy runner resolves to Busy with job details")
    func runningAndBusyRunner() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let diagLog = """
        [2026-10-15 22:30:00Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 22:30:02Z INFO Terminal] WRITE LINE: 2026-10-15 22:30:02Z: Listening for Jobs
        [2026-10-15 22:32:36Z INFO Terminal] WRITE LINE: 2026-10-15 22:32:36Z: Running job: build-and-test
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-223000-utc.log", diagLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logReader = RunnerLogReader()
        let logSnap = logReader.readSnapshot(for: candidate)
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: 4821,
            lastExitStatus: 0,
            runsCount: 1,
            stateDescription: "running"
        )

        let resolver = RunnerStatusResolver()
        let output = resolver.resolve(candidate: candidate, launchdSnapshot: launchdSnap, logSnapshot: logSnap)

        #expect(output.runner.status == .busy)
        #expect(output.runner.currentJob?.jobName == "build-and-test")
        #expect(output.runner.currentJob?.startedAt != nil)
        #expect(AggregateRunnerStatus.resolve(from: [output.runner]) == .busy)
    }

    // MARK: - 10. Job completion transition

    @Test("10. Job completion transitions from Busy back to Idle and emits jobCompleted event")
    func jobCompletionTransition() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let busyLog = """
        [2026-10-15 22:30:00Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 22:30:02Z INFO Terminal] WRITE LINE: 2026-10-15 22:30:02Z: Listening for Jobs
        [2026-10-15 22:32:36Z INFO Terminal] WRITE LINE: 2026-10-15 22:32:36Z: Running job: macOS Build
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-223000-utc.log", busyLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let logReader = RunnerLogReader()
        let resolver = RunnerStatusResolver()
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: 4821,
            lastExitStatus: 0,
            runsCount: 1,
            stateDescription: "running"
        )

        let candidate1 = try #require(discovery.discoverRunners(in: root).first)
        let busyRunner = resolver.resolve(
            candidate: candidate1,
            launchdSnapshot: launchdSnap,
            logSnapshot: logReader.readSnapshot(for: candidate1)
        ).runner
        #expect(busyRunner.status == .busy)

        // Append job completion line
        let completedLog = busyLog + "\n[2026-10-15 22:32:54Z INFO Terminal] WRITE LINE: 2026-10-15 22:32:54Z: Job macOS Build completed with result: Succeeded\n"
        let logFileURL = fixture.runnerDir.appendingPathComponent("_diag/Runner_20261015-223000-utc.log")
        try completedLog.write(to: logFileURL, atomically: true, encoding: .utf8)

        let candidate2 = try #require(discovery.discoverRunners(in: root).first)
        let afterOutput = resolver.resolve(
            candidate: candidate2,
            launchdSnapshot: launchdSnap,
            logSnapshot: logReader.readSnapshot(for: candidate2),
            previousRunner: busyRunner
        )

        #expect(afterOutput.runner.status == .idle)
        #expect(afterOutput.runner.currentJob == nil)
        #expect(afterOutput.runner.lastCompletedJob?.jobName == "macOS Build")
        #expect(afterOutput.runner.lastCompletedJob?.result == "Succeeded")
        #expect(afterOutput.emittedEvents.contains(where: { $0.kind == .jobCompleted }))
    }

    // MARK: - 11. Service stopped state

    @Test("11. Service stopped state resolves to Stopped")
    func serviceStoppedState() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: false,
            pid: nil,
            lastExitStatus: 0,
            stateDescription: "not loaded"
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: launchdSnap,
            logSnapshot: RunnerLogSnapshot()
        ).runner

        #expect(resolved.status == .stopped)
    }

    // MARK: - 12. Crash and automatic restart

    @Test("12. Crash and automatic restart increments restart count and transitions back to Idle")
    func crashAndAutomaticRestart() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let diagLog = """
        [2026-10-15 17:17:40Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: 2026-10-15 17:17:42Z: Listening for Jobs
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-171740-utc.log", diagLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logReader = RunnerLogReader()
        let resolver = RunnerStatusResolver()

        // Initial running state (PID 1001)
        let initialRunner = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: LaunchdServiceSnapshot(serviceName: fixture.serviceName, isLoaded: true, pid: 1001, runsCount: 1, stateDescription: "running"),
            logSnapshot: logReader.readSnapshot(for: candidate)
        ).runner
        #expect(initialRunner.status == .idle)
        #expect(initialRunner.restartCount == 0)

        // Crash while launchd is waiting to respawn
        let crashingOutput = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: LaunchdServiceSnapshot(serviceName: fixture.serviceName, isLoaded: true, pid: nil, lastExitStatus: 1, runsCount: 1, stateDescription: "waiting"),
            logSnapshot: logReader.readSnapshot(for: candidate),
            previousRunner: initialRunner
        )
        #expect(crashingOutput.runner.status == .restarting)
        #expect(crashingOutput.runner.restartCount == 1)
        #expect(crashingOutput.emittedEvents.contains(where: { $0.kind == .serviceRestarted }))

        // Replacement process starts (PID 1002) and writes new ready log
        let newDiagLog = """
        [2026-10-15 17:18:15Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:18:17Z INFO Terminal] WRITE LINE: 2026-10-15 17:18:17Z: Listening for Jobs
        """
        let newLogURL = fixture.runnerDir.appendingPathComponent("_diag/Runner_20261015-171815-utc.log")
        try newDiagLog.write(to: newLogURL, atomically: true, encoding: .utf8)

        let refreshedCandidate = try #require(discovery.discoverRunners(in: root).first)
        let recoveredOutput = resolver.resolve(
            candidate: refreshedCandidate,
            launchdSnapshot: LaunchdServiceSnapshot(serviceName: fixture.serviceName, isLoaded: true, pid: 1002, runsCount: 2, stateDescription: "running"),
            logSnapshot: logReader.readSnapshot(for: refreshedCandidate),
            previousRunner: crashingOutput.runner
        )
        #expect(recoveredOutput.runner.status == .idle)
        #expect(recoveredOutput.runner.servicePID == 1002)
        #expect(recoveredOutput.runner.restartCount == 1)
    }

    // MARK: - 13. Repeated crash / failed startup

    @Test("13. Repeated crash or fatal startup failure resolves to Failed with failure reason")
    func repeatedCrashFailedStartup() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let stdoutFatal = """
        Starting Runner listener with startup type: service
        Started listener process, pid: 5011
        Runner listener exited with error code 2
        Runner listener exit with retryable error, re-launch runner in 5 seconds.
        Stopping the runner after 10 consecutive re-tryable failures
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            stdoutContent: stdoutFatal
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logReader = RunnerLogReader()
        let logSnap = logReader.readSnapshot(for: candidate)
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: nil,
            lastExitStatus: 1,
            runsCount: 10,
            stateDescription: "exited"
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(candidate: candidate, launchdSnapshot: launchdSnap, logSnapshot: logSnap).runner

        #expect(resolved.status == .failed)
        #expect(resolved.lastFailureMessage?.contains("10 consecutive") == true)
    }

    // MARK: - 14. Stale log handling

    @Test("14. Stale log handling: new service process does not inherit Busy or Idle from an exited or older session log")
    func staleLogHandling() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        // Old session log that was Busy when the process died 1 hour ago
        let staleLog = """
        [2026-10-15 10:00:00Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 10:00:02Z INFO Terminal] WRITE LINE: 2026-10-15 10:00:02Z: Listening for Jobs
        [2026-10-15 10:05:00Z INFO Terminal] WRITE LINE: 2026-10-15 10:05:00Z: Running job: stale-job-from-earlier
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-100000-utc.log", staleLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logReader = RunnerLogReader()
        let logSnap = logReader.readSnapshot(for: candidate)
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: 9999,
            runsCount: 1,
            stateDescription: "running"
        )

        // New process started at 11:00:00Z (after 10:05:00Z stale log)
        let newProcessStart = RunnerLogReader.parseUTCTimestamp("2026-10-15 11:00:00Z")!
        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: launchdSnap,
            logSnapshot: logSnap,
            processStartedAt: newProcessStart
        ).runner

        #expect(resolved.status == .starting)
        #expect(resolved.currentJob == nil)
    }

    // MARK: - 15. Inaccessible files

    @Test("15. Inaccessible log files produce Unknown status with explanation without crashing")
    func inaccessibleFiles() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let candidate = try #require(RunnerDiscovery(launchAgentsDirectoryURL: launchAgents).discoverRunners(in: root).first)
        let inaccessibleLogSnap = RunnerLogSnapshot(
            hasRunSessionLog: false,
            logAccessError: "Permission denied reading Runner_20261015-171740-utc.log"
        )
        let launchdSnap = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: 4111,
            runsCount: 1,
            stateDescription: "running"
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: launchdSnap,
            logSnapshot: inaccessibleLogSnap
        ).runner

        #expect(resolved.status == .unknown)
        #expect(resolved.statusExplanation.contains("Permission denied"))
    }

    // MARK: - 16. Contradictory status evidence

    @Test("16. Contradictory status evidence resolves to Unknown with explanation")
    func contradictoryStatusEvidence() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let candidate = try #require(RunnerDiscovery(launchAgentsDirectoryURL: launchAgents).discoverRunners(in: root).first)
        // Contradictory launchd output: state claims "running" but pid is nil
        let contradictoryLaunchd = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: true,
            pid: nil,
            stateDescription: "running",
            querySucceeded: true
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: contradictoryLaunchd,
            logSnapshot: RunnerLogSnapshot()
        ).runner

        #expect(resolved.status == .unknown)
        #expect(resolved.statusExplanation.contains("Contradictory"))
    }

    // MARK: - 17. Log rotation / truncation

    @Test("17. Log rotation and truncation are handled safely without stale cursor errors")
    func logRotationAndTruncation() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let initialLog = """
        [2026-10-15 17:17:40Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: 2026-10-15 17:17:42Z: Listening for Jobs
        [2026-10-15 17:20:00Z INFO Terminal] WRITE LINE: 2026-10-15 17:20:00Z: Running job: long-job-with-lots-of-padding
        """ + "\n" + String(repeating: "# padding line\n", count: 50)

        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-171740-utc.log", initialLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let logReader = RunnerLogReader()

        let candidate1 = try #require(discovery.discoverRunners(in: root).first)
        let snap1 = logReader.readSnapshot(for: candidate1)
        #expect(snap1.currentJob?.jobName == "long-job-with-lots-of-padding")

        // Truncate the existing log file to a much shorter file (idle only)
        let truncatedLog = """
        [2026-10-15 18:00:00Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 18:00:02Z INFO Terminal] WRITE LINE: 2026-10-15 18:00:02Z: Listening for Jobs
        """
        let logURL = fixture.runnerDir.appendingPathComponent("_diag/Runner_20261015-171740-utc.log")
        try truncatedLog.write(to: logURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: logURL.path)

        let candidate2 = try #require(discovery.discoverRunners(in: root).first)
        let snap2 = logReader.readSnapshot(for: candidate2)
        #expect(snap2.isReady == true)
        #expect(snap2.currentJob == nil)
    }

    // MARK: - 18. Idempotent service setup

    @Test("18. Idempotent service setup generates valid plist and detects no changes needed on second run")
    func idempotentServiceSetup() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let backups = temp.appendingPathComponent("Backups")
        let root = temp.appendingPathComponent("actions-runners")

        _ = try createRunnerFixture(
            in: root,
            includeServiceFile: false,
            includePlist: false,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        let setupManager = ServiceSetupManager(
            discovery: RunnerDiscovery(launchAgentsDirectoryURL: launchAgents),
            launchdReader: MockLaunchdStatusReader(),
            launchAgentsDirectoryURL: launchAgents,
            logsRootDirectoryURL: logs,
            userName: "testuser",
            homeDirectoryURL: temp
        )

        // First run: should propose installAndConfigure
        let plan1 = setupManager.buildSetupPlan(in: root)
        #expect(plan1.count == 1)
        #expect(plan1[0].action == .installAndConfigure)

        try setupManager.applyConfiguration(for: plan1[0], backupRootURL: backups)

        // Second run: should propose .none (already configured idempotently)
        let plan2 = setupManager.buildSetupPlan(in: root)
        #expect(plan2.count == 1)
        #expect(plan2[0].action == .none)
    }

    // MARK: - 19. Invalid service configuration recovery

    @Test("19. Invalid service configuration is detected and repaired")
    func invalidServiceConfigRecovery() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let backups = temp.appendingPathComponent("Backups")
        let root = temp.appendingPathComponent("actions-runners")

        let fixture = try createRunnerFixture(
            in: root,
            includeServiceFile: true,
            includePlist: true,
            launchAgentsURL: launchAgents,
            logsRootURL: logs
        )

        // Break the plist WorkingDirectory
        let brokenPlist: [String: Any] = [
            "Label": fixture.serviceName,
            "ProgramArguments": ["/nonexistent/runsvc.sh"],
            "WorkingDirectory": "/wrong/directory"
        ]
        let brokenData = try PropertyListSerialization.data(fromPropertyList: brokenPlist, format: .xml, options: 0)
        try brokenData.write(to: fixture.plistURL)

        let setupManager = ServiceSetupManager(
            discovery: RunnerDiscovery(launchAgentsDirectoryURL: launchAgents),
            launchdReader: MockLaunchdStatusReader(),
            launchAgentsDirectoryURL: launchAgents,
            logsRootDirectoryURL: logs,
            userName: "testuser",
            homeDirectoryURL: temp
        )

        let plan = setupManager.buildSetupPlan(in: root)
        #expect(plan.count == 1)
        #expect(plan[0].action == .repairInvalidConfiguration)

        let backup = try setupManager.applyConfiguration(for: plan[0], backupRootURL: backups)
        #expect(backup?.backedUpPlistURL != nil)

        // After repair, discovery should report zero validation issues
        let afterCandidate = try #require(RunnerDiscovery(launchAgentsDirectoryURL: launchAgents).discoverRunners(in: root).first)
        #expect(afterCandidate.serviceConfig?.validationIssues.isEmpty == true)
        #expect(afterCandidate.serviceConfig?.isInstalled == true)
    }

    // MARK: - 20. Intentional service shutdown behavior

    @Test("20. Intentional service shutdown resolves to Stopped rather than Failed")
    func intentionalServiceShutdown() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let cleanExitLog = """
        [2026-10-15 17:17:40Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: 2026-10-15 17:17:42Z: Listening for Jobs
        [2026-10-15 23:14:07Z INFO Listener] Runner execution been cancelled.
        [2026-10-15 23:14:07Z INFO Terminal] WRITE LINE: Exiting...
        """
        let fixture = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [("Runner_20261015-171740-utc.log", cleanExitLog)]
        )

        let discovery = RunnerDiscovery(launchAgentsDirectoryURL: launchAgents)
        let candidate = try #require(discovery.discoverRunners(in: root).first)
        let logSnap = RunnerLogReader().readSnapshot(for: candidate)

        // Service was intentionally unloaded (`isLoaded == false`, exit status nil or 0)
        let unloadedLaunchd = LaunchdServiceSnapshot(
            serviceName: fixture.serviceName,
            isLoaded: false,
            pid: nil,
            lastExitStatus: nil,
            stateDescription: "not loaded"
        )

        let resolver = RunnerStatusResolver()
        let resolved = resolver.resolve(
            candidate: candidate,
            launchdSnapshot: unloadedLaunchd,
            logSnapshot: logSnap
        ).runner

        #expect(resolved.status == .stopped)
    }

    // MARK: - Additional Security & Format Tests

    @Test("SecretRedactor redacts GitHub tokens, Bearer headers, and pipeline URL tokens")
    func secretRedaction() {
        let raw = """
        Authorization: Bearer ghp_1234567890abcdefghijklmnopqrstuv
        Token is github_pat_11AABBCCDDEEFF00112233445566778899
        ServerUrl: https://pipelinesghubeus13.actions.githubusercontent.com/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/
        Adding option 'token': 'secret_reg_token_value'
        """
        let redacted = SecretRedactor.redact(raw)

        #expect(!redacted.contains("ghp_1234567890"))
        #expect(!redacted.contains("github_pat_11AABB"))
        #expect(!redacted.contains("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
        #expect(!redacted.contains("secret_reg_token_value"))
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test("Configure-only diagnostic log is skipped in favor of latest run session log")
    func skipsConfigureOnlyLog() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let launchAgents = temp.appendingPathComponent("LaunchAgents")
        let logs = temp.appendingPathComponent("Logs")
        let root = temp.appendingPathComponent("actions-runners")

        let runLog = """
        [2026-10-15 17:17:40Z INFO CommandLineParser] Adding Command: run
        [2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: 2026-10-15 17:17:42Z: Listening for Jobs
        [2026-10-15 22:32:36Z INFO Terminal] WRITE LINE: 2026-10-15 22:32:36Z: Running job: Build and Test
        [2026-10-15 22:32:54Z INFO Terminal] WRITE LINE: 2026-10-15 22:32:54Z: Job Build and Test completed with result: Succeeded
        """
        let configureLog = """
        [2026-10-15 23:14:26Z INFO CommandLineParser] Adding Command: configure
        [2026-10-15 23:14:26Z INFO ConfigurationManager] ConfigureAsync
        """

        _ = try createRunnerFixture(
            in: root,
            launchAgentsURL: launchAgents,
            logsRootURL: logs,
            diagLogs: [
                ("Runner_20261015-171740-utc.log", runLog),
                ("Runner_20261015-231426-utc.log", configureLog)
            ]
        )

        let candidate = try #require(RunnerDiscovery(launchAgentsDirectoryURL: launchAgents).discoverRunners(in: root).first)
        let logSnap = RunnerLogReader().readSnapshot(for: candidate)

        #expect(logSnap.hasRunSessionLog == true)
        #expect(logSnap.sessionLogURL?.lastPathComponent == "Runner_20261015-171740-utc.log")
        #expect(logSnap.lastCompletedJob?.jobName == "Build and Test")
    }

    @Test("Read-only verification of live ~/actions-runners installations if present")
    func readOnlyLiveRunnersVerification() throws {
        let liveRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners", isDirectory: true)
        guard FileManager.default.fileExists(atPath: liveRoot.path) else {
            return
        }

        let discovery = RunnerDiscovery()
        let logReader = RunnerLogReader()
        let launchdReader = LaunchdStatusReader()
        let resolver = RunnerStatusResolver()

        let candidates = discovery.discoverRunners(in: liveRoot)

        for candidate in candidates {
            let logSnap = logReader.readSnapshot(for: candidate)
            let launchdSnap = candidate.serviceConfig.map { launchdReader.readStatus(for: $0.serviceName) }
            let resolved = resolver.resolve(
                candidate: candidate,
                launchdSnapshot: launchdSnap,
                logSnapshot: logSnap
            ).runner

            #expect(!resolved.id.isEmpty)
            #expect(!resolved.displayName.isEmpty)
        }

        let livePlan = ServiceSetupManager().buildSetupPlan(in: liveRoot)
        #expect(livePlan.count == candidates.count)
    }
}
