import Foundation

/// Output of resolving a runner's status and any newly observed lifecycle events.
public struct RunnerResolutionOutput: Sendable, Equatable {
    public let runner: Runner
    public let emittedEvents: [RunnerEvent]

    public init(runner: Runner, emittedEvents: [RunnerEvent] = []) {
        self.runner = runner
        self.emittedEvents = emittedEvents
    }
}

/// Resolves authoritative local runner state from discovery metadata, `launchd` status, and log evidence.
public struct RunnerStatusResolver: Sendable {
    public init() {}

    public func resolve(
        candidate: DiscoveredRunnerCandidate,
        launchdSnapshot: LaunchdServiceSnapshot?,
        logSnapshot: RunnerLogSnapshot,
        previousRunner: Runner? = nil,
        processStartedAt: Date? = nil,
        now: Date = Date()
    ) -> RunnerResolutionOutput {
        let displayName = candidate.registration?.agentName ?? candidate.directoryName

        // 1. Check configuration validity (.notConfigured)
        if candidate.escapedRootBoundary ||
            !candidate.configurationErrors.isEmpty ||
            candidate.registration == nil ||
            !candidate.hasValidBinaries ||
            !candidate.hasCredentials {
            let reason = candidate.configurationErrors.first ?? "Runner installation or registration is incomplete."
            let runner = makeRunner(
                from: candidate,
                status: .notConfigured,
                explanation: reason,
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // 2. Check service installation (.notInstalled or invalid service config -> .failed)
        guard let serviceConfig = candidate.serviceConfig else {
            let runner = makeRunner(
                from: candidate,
                status: .notInstalled,
                explanation: "LaunchAgent service is not installed (.service configuration missing).",
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        if !serviceConfig.isServiceFilePresent && !serviceConfig.isPlistPresent {
            let runner = makeRunner(
                from: candidate,
                status: .notInstalled,
                explanation: "Service is not installed for \(displayName). Run service setup to install LaunchAgent.",
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        if !serviceConfig.validationIssues.isEmpty {
            let issue = serviceConfig.validationIssues.joined(separator: " ")
            let runner = makeRunner(
                from: candidate,
                status: .failed,
                explanation: issue,
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                overrideFailureMessage: issue,
                overrideFailureAt: now
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        if !serviceConfig.isServiceFilePresent || !serviceConfig.isPlistPresent {
            let runner = makeRunner(
                from: candidate,
                status: .notInstalled,
                explanation: "LaunchAgent configuration is incomplete (.service or .plist missing).",
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // 3. Evaluate launchd status
        guard let launchd = launchdSnapshot, launchd.querySucceeded else {
            let err = launchdSnapshot?.errorMessage ?? "Unable to query launchd service status."
            let runner = makeRunner(
                from: candidate,
                status: .unknown,
                explanation: err,
                launchdSnapshot: launchdSnapshot,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Detect contradictory launchd state (e.g. state says "running" but PID is nil)
        if launchd.stateDescription == "running" && (launchd.pid == nil || launchd.pid! <= 0) {
            let runner = makeRunner(
                from: candidate,
                status: .unknown,
                explanation: "Contradictory service state: launchd reports running state without a valid process ID.",
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // 4. Handle when service process is NOT running
        if !launchd.isRunning {
            // Contradictory evidence check: launchd says not running, but a log entry was written in the future/just now after a known stop
            if let logAccessError = logSnapshot.logAccessError, !logSnapshot.hasRunSessionLog {
                let runner = makeRunner(
                    from: candidate,
                    status: .unknown,
                    explanation: logAccessError,
                    launchdSnapshot: launchd,
                    logSnapshot: logSnapshot,
                    previousRunner: previousRunner,
                    includeActiveJob: false
                )
                return RunnerResolutionOutput(
                    runner: runner,
                    emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
                )
            }

            if logSnapshot.isServiceFatalFailureInStdout {
                let msg = logSnapshot.serviceStdoutFailureMessage ?? "Runner service stopped after repeated failures."
                let runner = makeRunner(
                    from: candidate,
                    status: .failed,
                    explanation: msg,
                    launchdSnapshot: launchd,
                    logSnapshot: logSnapshot,
                    previousRunner: previousRunner,
                    includeActiveJob: false,
                    overrideFailureMessage: msg,
                    overrideFailureAt: logSnapshot.lastErrorAt ?? now
                )
                return RunnerResolutionOutput(
                    runner: runner,
                    emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
                )
            }

            if let exitCode = launchd.lastExitStatus, exitCode != 0 {
                // If launchd still has the job loaded and KeepAlive is enabled, it may be in ThrottleInterval waiting to restart
                if launchd.isLoaded && serviceConfig.keepAlive && launchd.stateDescription == "waiting" {
                    let msg = "Service exited with code \(exitCode); launchd is throttling before restart."
                    let runner = makeRunner(
                        from: candidate,
                        status: .restarting,
                        explanation: msg,
                        launchdSnapshot: launchd,
                        logSnapshot: logSnapshot,
                        previousRunner: previousRunner,
                        includeActiveJob: false,
                        incrementRestart: previousRunner?.status != .restarting,
                        overrideFailureMessage: logSnapshot.lastErrorMessage ?? msg,
                        overrideFailureAt: logSnapshot.lastErrorAt ?? now
                    )
                    return RunnerResolutionOutput(
                        runner: runner,
                        emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
                    )
                }

                let failureReason = logSnapshot.lastErrorMessage
                    ?? logSnapshot.serviceStdoutFailureMessage
                    ?? "Service exited unexpectedly with status code \(exitCode)."
                let runner = makeRunner(
                    from: candidate,
                    status: .failed,
                    explanation: failureReason,
                    launchdSnapshot: launchd,
                    logSnapshot: logSnapshot,
                    previousRunner: previousRunner,
                    includeActiveJob: false,
                    overrideFailureMessage: failureReason,
                    overrideFailureAt: logSnapshot.lastErrorAt ?? now
                )
                return RunnerResolutionOutput(
                    runner: runner,
                    emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
                )
            }

            // If previously running and service is still loaded with KeepAlive, it is restarting
            if let prev = previousRunner,
               (prev.status == .idle || prev.status == .busy || prev.status == .starting),
               launchd.isLoaded,
               serviceConfig.keepAlive {
                let runner = makeRunner(
                    from: candidate,
                    status: .restarting,
                    explanation: "Service process disappeared; awaiting launchd recovery.",
                    launchdSnapshot: launchd,
                    logSnapshot: logSnapshot,
                    previousRunner: previousRunner,
                    includeActiveJob: false,
                    incrementRestart: true
                )
                return RunnerResolutionOutput(
                    runner: runner,
                    emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
                )
            }

            let runner = makeRunner(
                from: candidate,
                status: .stopped,
                explanation: launchd.isLoaded ? "Service is loaded but not running." : "Service is stopped.",
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // 5. Service process IS running (launchd.isRunning == true)
        let pidChanged: Bool = {
            guard let prevPID = previousRunner?.servicePID, let curPID = launchd.pid else {
                return false
            }
            return prevPID != curPID
        }()

        let listenerPIDChanged: Bool = {
            guard let prevListener = previousRunner?.listenerPID, let curListener = logSnapshot.listenerPID else {
                return false
            }
            return prevListener != curListener
        }()

        let wasRestarting = previousRunner?.status == .restarting
        let didRestart = pidChanged || listenerPIDChanged

        // Check if logs are inaccessible while running
        if let logAccessError = logSnapshot.logAccessError, !logSnapshot.hasRunSessionLog {
            let runner = makeRunner(
                from: candidate,
                status: .unknown,
                explanation: "Service is running (PID \(launchd.pid ?? 0)), but logs are inaccessible: \(logAccessError)",
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: didRestart
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Check if RunnerService.js is actively retrying after a listener crash
        if logSnapshot.isServiceRetryingInStdout {
            let msg = logSnapshot.serviceStdoutFailureMessage ?? "Runner listener exited; retrying in 5 seconds."
            let runner = makeRunner(
                from: candidate,
                status: .restarting,
                explanation: msg,
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: previousRunner?.status != .restarting,
                overrideFailureMessage: msg,
                overrideFailureAt: logSnapshot.lastErrorAt ?? now
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        if logSnapshot.isServiceFatalFailureInStdout {
            let msg = logSnapshot.serviceStdoutFailureMessage ?? "Runner listener failed fatally."
            let runner = makeRunner(
                from: candidate,
                status: .failed,
                explanation: msg,
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: didRestart,
                overrideFailureMessage: msg,
                overrideFailureAt: logSnapshot.lastErrorAt ?? now
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Must not display Idle or Busy merely because a process exists if no current session log exists
        guard logSnapshot.hasRunSessionLog else {
            let status: RunnerStatusState = (didRestart || wasRestarting) ? .restarting : .starting
            let explanation = status == .restarting
                ? "Replacement service started (PID \(launchd.pid ?? 0)); awaiting runner session log."
                : "Service started (PID \(launchd.pid ?? 0)); waiting for runner initialization."
            let runner = makeRunner(
                from: candidate,
                status: status,
                explanation: explanation,
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: didRestart
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Determine if the latest diagnostic log on disk is stale (from an earlier process instance)
        let isStaleSessionLog: Bool = {
            if logSnapshot.sessionExited {
                return true
            }
            if let procStart = processStartedAt,
               let lastActivity = logSnapshot.lastActivityAt,
               lastActivity.addingTimeInterval(2.0) < procStart {
                return true
            }
            return false
        }()

        if isStaleSessionLog {
            let status: RunnerStatusState = (didRestart || wasRestarting) ? .restarting : .starting
            let explanation = status == .restarting
                ? "Service restarted (PID \(launchd.pid ?? 0)); waiting for new session readiness."
                : "Service started (PID \(launchd.pid ?? 0)); previous session log has ended, waiting for new session."
            let runner = makeRunner(
                from: candidate,
                status: status,
                explanation: explanation,
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: didRestart
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Current session log is active: check job execution and readiness
        if let activeJob = logSnapshot.currentJob {
            let runner = makeRunner(
                from: candidate,
                status: .busy,
                explanation: "Running job: \(activeJob.jobName)",
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: true,
                incrementRestart: didRestart
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        if logSnapshot.isReady {
            let runner = makeRunner(
                from: candidate,
                status: .idle,
                explanation: "Waiting for jobs",
                launchdSnapshot: launchd,
                logSnapshot: logSnapshot,
                previousRunner: previousRunner,
                includeActiveJob: false,
                incrementRestart: didRestart
            )
            return RunnerResolutionOutput(
                runner: runner,
                emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
            )
        }

        // Session log exists for current instance, but has not yet logged "Listening for Jobs"
        let status: RunnerStatusState = (didRestart || wasRestarting) ? .restarting : .starting
        let explanation = status == .restarting
            ? "Service restarting (PID \(launchd.pid ?? 0)); connecting to GitHub Actions."
            : "Service starting (PID \(launchd.pid ?? 0)); connecting to GitHub Actions."
        let runner = makeRunner(
            from: candidate,
            status: status,
            explanation: explanation,
            launchdSnapshot: launchd,
            logSnapshot: logSnapshot,
            previousRunner: previousRunner,
            includeActiveJob: false,
            incrementRestart: didRestart
        )
        return RunnerResolutionOutput(
            runner: runner,
            emittedEvents: detectEvents(previous: previousRunner, current: runner, now: now)
        )
    }

    // MARK: - Helpers

    private func makeRunner(
        from candidate: DiscoveredRunnerCandidate,
        status: RunnerStatusState,
        explanation: String,
        launchdSnapshot: LaunchdServiceSnapshot?,
        logSnapshot: RunnerLogSnapshot,
        previousRunner: Runner?,
        includeActiveJob: Bool,
        incrementRestart: Bool = false,
        overrideFailureMessage: String? = nil,
        overrideFailureAt: Date? = nil
    ) -> Runner {
        let prevRestarts = previousRunner?.restartCount ?? 0
        let stdoutRestarts = logSnapshot.observedStdoutRestarts
        let launchdRunsRestarts = max(0, (launchdSnapshot?.runsCount ?? 1) - 1)
        var resolvedRestarts = max(prevRestarts, max(stdoutRestarts, launchdRunsRestarts))
        if incrementRestart {
            resolvedRestarts = max(resolvedRestarts, prevRestarts + 1)
        }

        let failureMessage = overrideFailureMessage
            ?? logSnapshot.lastErrorMessage
            ?? logSnapshot.serviceStdoutFailureMessage
            ?? previousRunner?.lastFailureMessage

        let failureAt = overrideFailureAt
            ?? logSnapshot.lastErrorAt
            ?? previousRunner?.lastFailureAt

        return Runner(
            id: candidate.id,
            directoryURL: candidate.directoryURL,
            directoryName: candidate.directoryName,
            registration: candidate.registration,
            hasValidBinaries: candidate.hasValidBinaries,
            hasCredentials: candidate.hasCredentials,
            serviceConfig: candidate.serviceConfig,
            status: status,
            statusExplanation: explanation,
            servicePID: launchdSnapshot?.pid,
            listenerPID: (launchdSnapshot?.isRunning == true) ? logSnapshot.listenerPID : nil,
            lastExitCode: launchdSnapshot?.lastExitStatus,
            currentJob: includeActiveJob ? logSnapshot.currentJob : nil,
            lastCompletedJob: logSnapshot.lastCompletedJob ?? previousRunner?.lastCompletedJob,
            lastActivityAt: logSnapshot.lastActivityAt ?? previousRunner?.lastActivityAt,
            lastFailureMessage: failureMessage,
            lastFailureAt: failureAt,
            restartCount: resolvedRestarts,
            runnerVersion: logSnapshot.runnerVersion ?? previousRunner?.runnerVersion,
            diagnosticLogURLs: candidate.diagnosticLogURLs
        )
    }

    private func detectEvents(previous: Runner?, current: Runner, now: Date) -> [RunnerEvent] {
        guard let previous else {
            var initialEvents: [RunnerEvent] = []
            if let activeJob = current.currentJob, current.status == .busy {
                initialEvents.append(
                    RunnerEvent(
                        timestamp: activeJob.startedAt ?? now,
                        runnerId: current.id,
                        runnerName: current.displayName,
                        kind: .jobStarted,
                        summary: "Job started: \(activeJob.jobName)",
                        detail: current.displayName
                    )
                )
            }
            return initialEvents
        }

        var events: [RunnerEvent] = []

        // 1. Restart or recovery transition
        if current.restartCount > previous.restartCount ||
            (previous.status != .restarting && current.status == .restarting) {
            events.append(
                RunnerEvent(
                    timestamp: now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .serviceRestarted,
                    summary: "Service restarted",
                    detail: current.statusExplanation
                )
            )
        } else if previous.status == .restarting && (current.status == .idle || current.status == .busy) {
            events.append(
                RunnerEvent(
                    timestamp: now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .serviceStarted,
                    summary: "Service recovered and ready",
                    detail: current.servicePID.map { "PID \($0)" }
                )
            )
        } else if (previous.status == .stopped || previous.status == .notInstalled) &&
                    (current.status == .starting || current.status == .idle || current.status == .busy) {
            events.append(
                RunnerEvent(
                    timestamp: now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .serviceStarted,
                    summary: "Service started",
                    detail: current.servicePID.map { "PID \($0)" }
                )
            )
        } else if (previous.status == .idle || previous.status == .busy || previous.status == .starting) &&
                    current.status == .stopped {
            events.append(
                RunnerEvent(
                    timestamp: now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .serviceStopped,
                    summary: "Service stopped",
                    detail: current.statusExplanation
                )
            )
        }

        // 2. Failure transition
        if previous.status != .failed && current.status == .failed {
            events.append(
                RunnerEvent(
                    timestamp: current.lastFailureAt ?? now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .serviceFailed,
                    summary: "Service failed",
                    detail: current.lastFailureMessage ?? current.statusExplanation
                )
            )
        }

        // 3. Job transitions
        if let completed = current.lastCompletedJob,
           completed != previous.lastCompletedJob {
            let resultText = completed.result.map { " (\($0))" } ?? ""
            events.append(
                RunnerEvent(
                    timestamp: completed.completedAt ?? now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .jobCompleted,
                    summary: "Job completed: \(completed.jobName)\(resultText)",
                    detail: completed.result
                )
            )
        }

        if let currentJob = current.currentJob,
           currentJob.jobName != previous.currentJob?.jobName || currentJob.startedAt != previous.currentJob?.startedAt {
            events.append(
                RunnerEvent(
                    timestamp: currentJob.startedAt ?? now,
                    runnerId: current.id,
                    runnerName: current.displayName,
                    kind: .jobStarted,
                    summary: "Job started: \(currentJob.jobName)",
                    detail: nil
                )
            )
        }

        return events
    }
}
