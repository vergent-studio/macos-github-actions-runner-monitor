import Foundation

public enum RunnerEventKind: String, Codable, Sendable, Equatable {
    case jobStarted
    case jobCompleted
    case serviceStarted
    case serviceStopped
    case serviceRestarted
    case serviceFailed
    case runnerDiscovered
    case runnerRemoved

    public var symbolName: String {
        switch self {
        case .jobStarted:
            return "play.fill"
        case .jobCompleted:
            return "checkmark.circle.fill"
        case .serviceStarted:
            return "power.circle.fill"
        case .serviceStopped:
            return "stop.circle.fill"
        case .serviceRestarted:
            return "arrow.clockwise.circle.fill"
        case .serviceFailed:
            return "exclamationmark.triangle.fill"
        case .runnerDiscovered:
            return "plus.circle.fill"
        case .runnerRemoved:
            return "minus.circle.fill"
        }
    }
}

/// Lifecycle or job event observed locally for a runner.
public struct RunnerEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let runnerId: String
    public let runnerName: String
    public let kind: RunnerEventKind
    public let summary: String
    public let detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        runnerId: String,
        runnerName: String,
        kind: RunnerEventKind,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.runnerId = runnerId
        self.runnerName = runnerName
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

public enum LogLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERR"
    case other = "LOG"
}

public enum LogSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case diagnosticRunner = "Runner Diagnostic"
    case diagnosticWorker = "Worker Diagnostic"
    case standardOut = "Service stdout"
    case standardError = "Service stderr"
}

/// A parsed and redacted log line for display in the bounded log viewer.
public struct RunnerLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date?
    public let rawTimestamp: String?
    public let level: LogLevel
    public let component: String?
    public let message: String
    public let sourceName: String
    public let sourceKind: LogSourceKind

    public init(
        id: UUID = UUID(),
        timestamp: Date? = nil,
        rawTimestamp: String? = nil,
        level: LogLevel,
        component: String? = nil,
        message: String,
        sourceName: String,
        sourceKind: LogSourceKind
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawTimestamp = rawTimestamp
        self.level = level
        self.component = component
        self.message = message
        self.sourceName = sourceName
        self.sourceKind = sourceKind
    }
}
