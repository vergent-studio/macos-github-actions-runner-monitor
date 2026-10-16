import Foundation

/// Typed status model representing the local state of a GitHub Actions runner.
/// Distinguishes verified local facts from uncertainty without assuming GitHub connectivity.
public enum RunnerStatusState: String, Codable, Sendable, CaseIterable, Equatable {
    /// Runner installation or registration is incomplete (e.g. missing .runner, config.sh, or run.sh).
    case notConfigured = "Not configured"
    /// Runner exists and is registered, but LaunchAgent service configuration is missing.
    case notInstalled = "Not installed"
    /// Service is installed, but not currently running.
    case stopped = "Stopped"
    /// Service process has started, but readiness ("Listening for Jobs") has not yet been established for this instance.
    case starting = "Starting"
    /// Current service instance has reported readiness and is waiting for jobs.
    case idle = "Idle"
    /// Current service instance has reported active job execution.
    case busy = "Busy"
    /// A restart attempt has been observed (either via RunnerService retry or launchd respawn).
    case restarting = "Restarting"
    /// A verified service or startup failure occurred.
    case failed = "Failed"
    /// Available local information is insufficient or contradictory.
    case unknown = "Unknown"

    public var displayTitle: String {
        rawValue
    }

    public var badgeText: String {
        switch self {
        case .notConfigured: return "NOT CONFIGURED"
        case .notInstalled: return "NOT INSTALLED"
        case .stopped: return "STOPPED"
        case .starting: return "STARTING"
        case .idle: return "IDLE"
        case .busy: return "BUSY"
        case .restarting: return "RESTARTING"
        case .failed: return "FAILED"
        case .unknown: return "UNKNOWN"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle:
            return "checkmark.circle.fill"
        case .busy:
            return "play.circle.fill"
        case .starting, .restarting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .stopped:
            return "pause.circle.fill"
        case .notInstalled:
            return "tray.and.arrow.down.fill"
        case .notConfigured:
            return "wrench.and.screwdriver.fill"
        case .failed:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    public var isHealthyActive: Bool {
        self == .idle || self == .busy
    }

    public var isProblemState: Bool {
        switch self {
        case .stopped, .failed, .notConfigured, .notInstalled:
            return true
        case .starting, .idle, .busy, .restarting, .unknown:
            return false
        }
    }
}

/// Aggregate status across all discovered runners for the menu bar indicator.
public enum AggregateRunnerStatus: String, Sendable, Equatable {
    case allIdle
    case busy
    case degraded
    case unknown

    public var title: String {
        switch self {
        case .allIdle:
            return "All runners idle"
        case .busy:
            return "Runner busy"
        case .degraded:
            return "Runner attention needed"
        case .unknown:
            return "Runner status unavailable"
        }
    }

    public var symbolName: String {
        switch self {
        case .allIdle:
            return "checkmark.circle"
        case .busy:
            return "gearshape.2.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    public static func resolve(from runners: [Runner]) -> AggregateRunnerStatus {
        guard !runners.isEmpty else {
            return .unknown
        }

        let states = runners.map(\.status)
        if states.contains(where: { $0 == .failed || $0 == .stopped || $0 == .notInstalled || $0 == .notConfigured }) {
            return .degraded
        }
        if states.contains(.unknown) {
            return .unknown
        }
        if states.contains(.busy) {
            return .busy
        }
        if states.contains(.starting) || states.contains(.restarting) {
            return .busy
        }
        if states.allSatisfy({ $0 == .idle }) {
            return .allIdle
        }
        return .unknown
    }
}
