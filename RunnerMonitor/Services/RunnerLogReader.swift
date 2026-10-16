import Foundation

/// Parsed evidence from a runner's diagnostic and service logs.
public struct RunnerLogSnapshot: Sendable, Equatable {
    public let hasRunSessionLog: Bool
    public let sessionLogURL: URL?
    public let sessionStartedAt: Date?
    public let runnerVersion: String?
    public let isReady: Bool
    public let readyAt: Date?
    public let currentJob: RunnerJobInfo?
    public let lastCompletedJob: RunnerJobInfo?
    public let sessionExited: Bool
    public let sessionExitedAt: Date?
    public let lastActivityAt: Date?
    public let lastErrorMessage: String?
    public let lastErrorAt: Date?
    public let listenerPID: Int32?
    public let isServiceRetryingInStdout: Bool
    public let isServiceFatalFailureInStdout: Bool
    public let serviceStdoutFailureMessage: String?
    public let observedStdoutRestarts: Int
    public let recentJobEvents: [RunnerJobInfo]
    public let logAccessError: String?

    public init(
        hasRunSessionLog: Bool = false,
        sessionLogURL: URL? = nil,
        sessionStartedAt: Date? = nil,
        runnerVersion: String? = nil,
        isReady: Bool = false,
        readyAt: Date? = nil,
        currentJob: RunnerJobInfo? = nil,
        lastCompletedJob: RunnerJobInfo? = nil,
        sessionExited: Bool = false,
        sessionExitedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        lastErrorMessage: String? = nil,
        lastErrorAt: Date? = nil,
        listenerPID: Int32? = nil,
        isServiceRetryingInStdout: Bool = false,
        isServiceFatalFailureInStdout: Bool = false,
        serviceStdoutFailureMessage: String? = nil,
        observedStdoutRestarts: Int = 0,
        recentJobEvents: [RunnerJobInfo] = [],
        logAccessError: String? = nil
    ) {
        self.hasRunSessionLog = hasRunSessionLog
        self.sessionLogURL = sessionLogURL
        self.sessionStartedAt = sessionStartedAt
        self.runnerVersion = runnerVersion
        self.isReady = isReady
        self.readyAt = readyAt
        self.currentJob = currentJob
        self.lastCompletedJob = lastCompletedJob
        self.sessionExited = sessionExited
        self.sessionExitedAt = sessionExitedAt
        self.lastActivityAt = lastActivityAt
        self.lastErrorMessage = lastErrorMessage
        self.lastErrorAt = lastErrorAt
        self.listenerPID = listenerPID
        self.isServiceRetryingInStdout = isServiceRetryingInStdout
        self.isServiceFatalFailureInStdout = isServiceFatalFailureInStdout
        self.serviceStdoutFailureMessage = serviceStdoutFailureMessage
        self.observedStdoutRestarts = observedStdoutRestarts
        self.recentJobEvents = recentJobEvents
        self.logAccessError = logAccessError
    }
}

/// Reads and parses official GitHub runner diagnostic logs (`_diag/Runner_*.log`, `Worker_*.log`)
/// and LaunchAgent stdout/stderr logs using bounded tail reads.
/// Never modifies log files or loads entire large historical files into memory.
public final class RunnerLogReader: @unchecked Sendable {
    private struct FileCursor {
        let inode: UInt64
        let size: UInt64
        let modificationDate: Date?
        let cachedTailText: String
    }

    private let lock = NSLock()
    private var fileCursors: [String: FileCursor] = [:]
    public let maxTailBytes: Int

    public init(maxTailBytes: Int = 256 * 1024) {
        self.maxTailBytes = maxTailBytes
    }

    public func readSnapshot(for candidate: DiscoveredRunnerCandidate) -> RunnerLogSnapshot {
        let runnerLogs = candidate.diagnosticLogURLs.filter { $0.lastPathComponent.hasPrefix("Runner_") }

        var selectedLogURL: URL?
        var selectedLogText: String?
        var accessError: String?

        // Find the most recent `Runner_*.log` that represents a `run` session (skip `configure`-only logs)
        for logURL in runnerLogs.prefix(6) {
            switch readBoundedTail(of: logURL, maxBytes: maxTailBytes) {
            case .success(let content):
                if Self.isConfigureOnlyLog(content) {
                    continue
                }
                selectedLogURL = logURL
                selectedLogText = content
                break
            case .failure(let error):
                if accessError == nil {
                    accessError = "Unable to read \(logURL.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }

        // Also inspect service stdout/stderr if configured
        var listenerPID: Int32?
        var isServiceRetrying = false
        var isServiceFatalFailure = false
        var serviceStdoutFailureMessage: String?
        var observedStdoutRestarts = 0

        if let stdoutURL = candidate.serviceConfig?.standardOutURL,
           FileManager.default.fileExists(atPath: stdoutURL.path),
           case .success(let stdoutText) = readBoundedTail(of: stdoutURL, maxBytes: 128 * 1024) {
            let stdoutInfo = Self.parseServiceStdout(stdoutText)
            listenerPID = stdoutInfo.listenerPID
            isServiceRetrying = stdoutInfo.isRetrying
            isServiceFatalFailure = stdoutInfo.isFatalFailure
            serviceStdoutFailureMessage = stdoutInfo.failureMessage
            observedStdoutRestarts = stdoutInfo.restartCount
        }

        if let stderrURL = candidate.serviceConfig?.standardErrorURL,
           FileManager.default.fileExists(atPath: stderrURL.path),
           case .success(let stderrText) = readBoundedTail(of: stderrURL, maxBytes: 64 * 1024) {
            let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let lastLine = trimmed.components(separatedBy: .newlines).last {
                let redacted = SecretRedactor.redact(lastLine)
                if lastLine.localizedCaseInsensitiveContains("Stopping the runner after") ||
                    lastLine.localizedCaseInsensitiveContains("Failed:") {
                    isServiceFatalFailure = true
                    serviceStdoutFailureMessage = redacted
                } else if serviceStdoutFailureMessage == nil {
                    serviceStdoutFailureMessage = redacted
                }
            }
        }

        guard let logURL = selectedLogURL, let logText = selectedLogText else {
            return RunnerLogSnapshot(
                hasRunSessionLog: false,
                listenerPID: listenerPID,
                isServiceRetryingInStdout: isServiceRetrying,
                isServiceFatalFailureInStdout: isServiceFatalFailure,
                serviceStdoutFailureMessage: serviceStdoutFailureMessage,
                observedStdoutRestarts: observedStdoutRestarts,
                logAccessError: accessError
            )
        }

        // Also read the head of the selected log (first 8 KB) to get session start time and version if the file was larger than maxTailBytes
        let headText = (try? Self.readHead(of: logURL, maxBytes: 8 * 1024)) ?? ""
        return Self.parseRunnerDiagnosticLog(
            headText: headText,
            tailText: logText,
            logURL: logURL,
            listenerPID: listenerPID,
            isServiceRetryingInStdout: isServiceRetrying,
            isServiceFatalFailureInStdout: isServiceFatalFailure,
            serviceStdoutFailureMessage: serviceStdoutFailureMessage,
            observedStdoutRestarts: observedStdoutRestarts,
            logAccessError: accessError
        )
    }

    /// Reads and redacts log entries for the bounded log viewer.
    public func readLogEntries(for runner: Runner, maxEntries: Int = 300) -> [RunnerLogEntry] {
        var entries: [RunnerLogEntry] = []

        // 1. Read from up to 2 most recent Runner_*.log files and 1 Worker_*.log file
        let runnerDiagLogs = runner.diagnosticLogURLs.filter { $0.lastPathComponent.hasPrefix("Runner_") }.prefix(2)
        let workerDiagLogs = runner.diagnosticLogURLs.filter { $0.lastPathComponent.hasPrefix("Worker_") }.prefix(1)

        for url in runnerDiagLogs {
            if case .success(let text) = readBoundedTail(of: url, maxBytes: 128 * 1024) {
                entries.append(contentsOf: Self.parseLogEntries(from: text, sourceName: url.lastPathComponent, sourceKind: .diagnosticRunner, limit: maxEntries))
            }
        }

        for url in workerDiagLogs {
            if case .success(let text) = readBoundedTail(of: url, maxBytes: 64 * 1024) {
                entries.append(contentsOf: Self.parseLogEntries(from: text, sourceName: url.lastPathComponent, sourceKind: .diagnosticWorker, limit: maxEntries / 2))
            }
        }

        // 2. Read from service stdout and stderr if available
        if let stdoutURL = runner.serviceConfig?.standardOutURL,
           FileManager.default.fileExists(atPath: stdoutURL.path),
           case .success(let text) = readBoundedTail(of: stdoutURL, maxBytes: 64 * 1024) {
            entries.append(contentsOf: Self.parseLogEntries(from: text, sourceName: "stdout.log", sourceKind: .standardOut, limit: maxEntries / 2))
        }

        if let stderrURL = runner.serviceConfig?.standardErrorURL,
           FileManager.default.fileExists(atPath: stderrURL.path),
           case .success(let text) = readBoundedTail(of: stderrURL, maxBytes: 64 * 1024) {
            entries.append(contentsOf: Self.parseLogEntries(from: text, sourceName: "stderr.log", sourceKind: .standardError, limit: maxEntries / 2))
        }

        // Sort entries chronologically when timestamps are available, keeping recent entries bounded
        let sorted = entries.sorted { a, b in
            switch (a.timestamp, b.timestamp) {
            case let (ta?, tb?):
                return ta < tb
            default:
                return false
            }
        }

        if sorted.count > maxEntries {
            return Array(sorted.suffix(maxEntries))
        }
        return sorted
    }

    // MARK: - Bounded & Rotation-Safe File Reading

    public func readBoundedTail(of fileURL: URL, maxBytes: Int) -> Result<String, Error> {
        let path = fileURL.path
        let fileManager = FileManager.default

        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modDate = attrs[.modificationDate] as? Date

            lock.lock()
            if let cached = fileCursors[path],
               cached.inode == inode,
               cached.size == fileSize,
               cached.modificationDate == modDate {
                let text = cached.cachedTailText
                lock.unlock()
                return .success(text)
            }
            lock.unlock()

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer {
                try? handle.close()
            }

            let readLimit = UInt64(max(1024, maxBytes))
            var startOffset: UInt64 = 0
            if fileSize > readLimit {
                startOffset = fileSize - readLimit
                try handle.seek(toOffset: startOffset)
            }

            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)

            // If we seeked into the middle of the file, drop the partial first line
            if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }

            lock.lock()
            fileCursors[path] = FileCursor(
                inode: inode,
                size: fileSize,
                modificationDate: modDate,
                cachedTailText: text
            )
            lock.unlock()

            return .success(text)
        } catch {
            lock.lock()
            fileCursors.removeValue(forKey: path)
            lock.unlock()
            return .failure(error)
        }
    }

    private static func readHead(of fileURL: URL, maxBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Log Format Parsing

    public static func isConfigureOnlyLog(_ text: String) -> Bool {
        let hasConfigureCommand = text.contains("Adding Command: configure") || text.contains("Command 'configure': 'True'")
        let hasRunCommand = text.contains("Adding Command: run") || text.contains("Listening for Jobs") || text.contains("Running job:")
        return hasConfigureCommand && !hasRunCommand
    }

    public static func parseRunnerDiagnosticLog(
        headText: String,
        tailText: String,
        logURL: URL,
        listenerPID: Int32? = nil,
        isServiceRetryingInStdout: Bool = false,
        isServiceFatalFailureInStdout: Bool = false,
        serviceStdoutFailureMessage: String? = nil,
        observedStdoutRestarts: Int = 0,
        logAccessError: String? = nil
    ) -> RunnerLogSnapshot {
        var sessionStartedAt: Date?
        var runnerVersion: String?
        var isReady = false
        var readyAt: Date?
        var activeJobName: String?
        var activeJobStartedAt: Date?
        var lastCompletedJob: RunnerJobInfo?
        var recentJobEvents: [RunnerJobInfo] = []
        var sessionExited = false
        var sessionExitedAt: Date?
        var lastActivityAt: Date?
        var lastErrorMessage: String?
        var lastErrorAt: Date?

        // Inspect head lines for initial timestamp & version
        if !headText.isEmpty {
            for rawLine in headText.components(separatedBy: .newlines).prefix(40) {
                if let parsed = parseBracketedDiagnosticLine(rawLine) {
                    if sessionStartedAt == nil, let ts = parsed.timestamp {
                        sessionStartedAt = ts
                    }
                    if runnerVersion == nil, parsed.component == "Listener", parsed.message.hasPrefix("Version: ") {
                        runnerVersion = String(parsed.message.dropFirst("Version: ".count)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // Inspect tail lines for lifecycle transitions, jobs, and errors
        for rawLine in tailText.components(separatedBy: .newlines) {
            guard !rawLine.isEmpty else { continue }
            guard let parsed = parseBracketedDiagnosticLine(rawLine) else { continue }

            if sessionStartedAt == nil, let ts = parsed.timestamp {
                sessionStartedAt = ts
            }
            if let ts = parsed.timestamp {
                lastActivityAt = ts
            }

            if runnerVersion == nil, parsed.component == "Listener", parsed.message.hasPrefix("Version: ") {
                runnerVersion = String(parsed.message.dropFirst("Version: ".count)).trimmingCharacters(in: .whitespaces)
            }

            if parsed.level == .error {
                let msg = SecretRedactor.redact(parsed.message)
                // Ignore separator hashes
                if !msg.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).isEmpty {
                    lastErrorMessage = msg
                    lastErrorAt = parsed.timestamp
                }
            }

            // Readiness markers
            if parsed.message.contains("Listening for Jobs") ||
                (parsed.component == "BrokerMessageListener" && parsed.message == "Session created.") ||
                (parsed.component == "MessageListener" && parsed.message == "Session created.") {
                isReady = true
                if readyAt == nil {
                    readyAt = parsed.timestamp
                }
                sessionExited = false
            }

            // Terminal WRITE LINE markers for jobs and exit
            if parsed.component == "Terminal", parsed.message.hasPrefix("WRITE LINE:") {
                let writeContent = String(parsed.message.dropFirst("WRITE LINE:".count)).trimmingCharacters(in: .whitespaces)

                if let runningRange = writeContent.range(of: "Running job: ") {
                    let jobName = String(writeContent[runningRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !jobName.isEmpty {
                        isReady = true
                        sessionExited = false
                        activeJobName = jobName
                        activeJobStartedAt = parsed.timestamp
                    }
                } else if let jobPrefixRange = writeContent.range(of: ": Job "),
                          let completedRange = writeContent.range(of: " completed with result: ") {
                    let jobName = String(writeContent[jobPrefixRange.upperBound..<completedRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let result = String(writeContent[completedRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let started = (activeJobName == jobName) ? activeJobStartedAt : nil
                    let completedJob = RunnerJobInfo(
                        jobName: jobName,
                        startedAt: started,
                        completedAt: parsed.timestamp,
                        result: result
                    )
                    lastCompletedJob = completedJob
                    recentJobEvents.append(completedJob)
                    if activeJobName == jobName {
                        activeJobName = nil
                        activeJobStartedAt = nil
                    }
                } else if writeContent == "Exiting..." {
                    sessionExited = true
                    sessionExitedAt = parsed.timestamp
                }
            }

            if parsed.component == "Listener" &&
                (parsed.message.contains("Runner execution been cancelled") ||
                 parsed.message.contains("Runner listener exited")) {
                sessionExited = true
                sessionExitedAt = parsed.timestamp
            }
        }

        let currentJob: RunnerJobInfo?
        if let activeJobName, !sessionExited {
            currentJob = RunnerJobInfo(jobName: activeJobName, startedAt: activeJobStartedAt)
        } else {
            currentJob = nil
        }

        return RunnerLogSnapshot(
            hasRunSessionLog: true,
            sessionLogURL: logURL,
            sessionStartedAt: sessionStartedAt,
            runnerVersion: runnerVersion,
            isReady: isReady,
            readyAt: readyAt,
            currentJob: currentJob,
            lastCompletedJob: lastCompletedJob,
            sessionExited: sessionExited,
            sessionExitedAt: sessionExitedAt,
            lastActivityAt: lastActivityAt,
            lastErrorMessage: lastErrorMessage,
            lastErrorAt: lastErrorAt,
            listenerPID: listenerPID,
            isServiceRetryingInStdout: isServiceRetryingInStdout,
            isServiceFatalFailureInStdout: isServiceFatalFailureInStdout,
            serviceStdoutFailureMessage: serviceStdoutFailureMessage,
            observedStdoutRestarts: observedStdoutRestarts,
            recentJobEvents: recentJobEvents,
            logAccessError: logAccessError
        )
    }

    public struct StdoutParseResult: Sendable, Equatable {
        public let listenerPID: Int32?
        public let isRetrying: Bool
        public let isFatalFailure: Bool
        public let failureMessage: String?
        public let restartCount: Int
    }

    public static func parseServiceStdout(_ text: String) -> StdoutParseResult {
        var listenerPID: Int32?
        var isRetrying = false
        var isFatalFailure = false
        var failureMessage: String?
        var restartCount = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("Started listener process, pid: ") {
                let pidStr = line.dropFirst("Started listener process, pid: ".count).trimmingCharacters(in: .whitespaces)
                listenerPID = Int32(pidStr)
                isRetrying = false
                isFatalFailure = false
            } else if line.contains("Listening for Jobs") {
                isRetrying = false
                isFatalFailure = false
            } else if line.contains("re-launch runner in 5 seconds") {
                isRetrying = true
                restartCount += 1
                failureMessage = SecretRedactor.redact(line)
            } else if line.contains("Stopping the runner after 10 consecutive") ||
                        line.contains("Session Conflict error, stop the service") ||
                        line.contains("Runner listener exit with terminated error") ||
                        line.hasPrefix("Runner listener fail to start") {
                isRetrying = false
                isFatalFailure = true
                failureMessage = SecretRedactor.redact(line)
            }
        }

        return StdoutParseResult(
            listenerPID: listenerPID,
            isRetrying: isRetrying,
            isFatalFailure: isFatalFailure,
            failureMessage: failureMessage,
            restartCount: restartCount
        )
    }

    public struct ParsedDiagnosticLine {
        public let rawTimestamp: String
        public let timestamp: Date?
        public let level: LogLevel
        public let component: String
        public let message: String
    }

    /// Parses lines formatted like: `[2026-10-15 17:17:42Z INFO Terminal] WRITE LINE: ...`
    public static func parseBracketedDiagnosticLine(_ line: String) -> ParsedDiagnosticLine? {
        guard line.hasPrefix("["),
              let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }

        let header = String(line[line.index(after: line.startIndex)..<closingBracket])
        let messageStart = line.index(after: closingBracket)
        let message = String(line[messageStart...]).trimmingCharacters(in: .whitespaces)

        // Header format: "2026-10-15 17:17:42Z INFO ComponentName"
        // Timestamp is first 20 chars ("YYYY-MM-DD HH:MM:SSZ")
        guard header.count >= 25 else { return nil }
        let tsEndIndex = header.index(header.startIndex, offsetBy: 20)
        let rawTimestamp = String(header[..<tsEndIndex])
        let remainder = String(header[tsEndIndex...]).trimmingCharacters(in: .whitespaces)

        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }

        let levelToken = String(parts[0])
        let component = parts.count > 1 ? String(parts[1]) : ""

        let level: LogLevel
        switch levelToken {
        case "INFO": level = .info
        case "WARN": level = .warning
        case "ERR": level = .error
        default: level = .other
        }

        return ParsedDiagnosticLine(
            rawTimestamp: rawTimestamp,
            timestamp: parseUTCTimestamp(rawTimestamp),
            level: level,
            component: component,
            message: message
        )
    }

    public static func parseLogEntries(
        from text: String,
        sourceName: String,
        sourceKind: LogSourceKind,
        limit: Int
    ) -> [RunnerLogEntry] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tailLines = lines.count > limit ? Array(lines.suffix(limit)) : lines

        var entries: [RunnerLogEntry] = []
        entries.reserveCapacity(tailLines.count)

        for rawLine in tailLines {
            if let parsed = parseBracketedDiagnosticLine(rawLine) {
                entries.append(
                    RunnerLogEntry(
                        timestamp: parsed.timestamp,
                        rawTimestamp: parsed.rawTimestamp,
                        level: parsed.level,
                        component: parsed.component,
                        message: SecretRedactor.redact(parsed.message),
                        sourceName: sourceName,
                        sourceKind: sourceKind
                    )
                )
            } else {
                let redacted = SecretRedactor.redact(rawLine)
                let inferredLevel: LogLevel
                if rawLine.localizedCaseInsensitiveContains("error") || rawLine.localizedCaseInsensitiveContains("exception") || rawLine.localizedCaseInsensitiveContains("failed") {
                    inferredLevel = .error
                } else if rawLine.localizedCaseInsensitiveContains("warn") {
                    inferredLevel = .warning
                } else {
                    inferredLevel = .other
                }
                entries.append(
                    RunnerLogEntry(
                        timestamp: nil,
                        rawTimestamp: nil,
                        level: inferredLevel,
                        component: nil,
                        message: redacted,
                        sourceName: sourceName,
                        sourceKind: sourceKind
                    )
                )
            }
        }
        return entries
    }

    public static func parseUTCTimestamp(_ string: String) -> Date? {
        // Fast ISO-like parser for "YYYY-MM-DD HH:MM:SSZ"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let isoCandidate = string.replacingOccurrences(of: " ", with: "T")
        return formatter.date(from: isoCandidate)
    }
}
