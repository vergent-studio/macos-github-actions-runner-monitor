import Foundation

/// Metadata parsed from a runner's `.runner` JSON file.
public struct RunnerRegistration: Codable, Sendable, Equatable {
    public let agentId: Int
    public let agentName: String
    public let poolId: Int?
    public let poolName: String?
    public let serverUrl: String?
    public let gitHubUrl: String?
    public let workFolder: String?
    public let useV2Flow: Bool?
    public let serverUrlV2: String?

    public init(
        agentId: Int,
        agentName: String,
        poolId: Int? = nil,
        poolName: String? = nil,
        serverUrl: String? = nil,
        gitHubUrl: String? = nil,
        workFolder: String? = nil,
        useV2Flow: Bool? = nil,
        serverUrlV2: String? = nil
    ) {
        self.agentId = agentId
        self.agentName = agentName
        self.poolId = poolId
        self.poolName = poolName
        self.serverUrl = serverUrl
        self.gitHubUrl = gitHubUrl
        self.workFolder = workFolder
        self.useV2Flow = useV2Flow
        self.serverUrlV2 = serverUrlV2
    }

    /// Extracts a concise owner/repository or organization label from `gitHubUrl` when available.
    public var repositoryDisplayName: String? {
        guard let gitHubUrl, let url = URL(string: gitHubUrl) else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? gitHubUrl : path
    }
}

/// Service configuration discovered from `.service`, `svc.sh`, and the LaunchAgent property list.
public struct RunnerServiceConfig: Codable, Sendable, Equatable {
    public let serviceName: String
    public let plistURL: URL?
    public let isServiceFilePresent: Bool
    public let isPlistPresent: Bool
    public let standardOutURL: URL?
    public let standardErrorURL: URL?
    public let workingDirectoryURL: URL?
    public let programArguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let throttleInterval: Int?
    public let validationIssues: [String]

    public init(
        serviceName: String,
        plistURL: URL?,
        isServiceFilePresent: Bool,
        isPlistPresent: Bool,
        standardOutURL: URL? = nil,
        standardErrorURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        programArguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        throttleInterval: Int? = nil,
        validationIssues: [String] = []
    ) {
        self.serviceName = serviceName
        self.plistURL = plistURL
        self.isServiceFilePresent = isServiceFilePresent
        self.isPlistPresent = isPlistPresent
        self.standardOutURL = standardOutURL
        self.standardErrorURL = standardErrorURL
        self.workingDirectoryURL = workingDirectoryURL
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.throttleInterval = throttleInterval
        self.validationIssues = validationIssues
    }

    public var isInstalled: Bool {
        isServiceFilePresent && isPlistPresent && validationIssues.isEmpty
    }
}

/// Information about an active or recently completed CI job observed in local runner logs.
public struct RunnerJobInfo: Codable, Sendable, Equatable {
    public let jobName: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let result: String?

    public init(
        jobName: String,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        result: String? = nil
    ) {
        self.jobName = jobName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
    }

    public func elapsedDuration(at referenceDate: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        let end = completedAt ?? referenceDate
        return max(0, end.timeIntervalSince(startedAt))
    }

    public static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

/// Complete resolved model for a single discovered runner installation.
public struct Runner: Identifiable, Sendable, Equatable {
    public let id: String
    public let directoryURL: URL
    public let directoryName: String
    public let registration: RunnerRegistration?
    public let hasValidBinaries: Bool
    public let hasCredentials: Bool
    public let serviceConfig: RunnerServiceConfig?
    public let status: RunnerStatusState
    public let statusExplanation: String
    public let servicePID: Int32?
    public let listenerPID: Int32?
    public let lastExitCode: Int32?
    public let currentJob: RunnerJobInfo?
    public let lastCompletedJob: RunnerJobInfo?
    public let lastActivityAt: Date?
    public let lastFailureMessage: String?
    public let lastFailureAt: Date?
    public let restartCount: Int
    public let runnerVersion: String?
    public let diagnosticLogURLs: [URL]

    public init(
        id: String,
        directoryURL: URL,
        directoryName: String,
        registration: RunnerRegistration? = nil,
        hasValidBinaries: Bool = false,
        hasCredentials: Bool = false,
        serviceConfig: RunnerServiceConfig? = nil,
        status: RunnerStatusState,
        statusExplanation: String,
        servicePID: Int32? = nil,
        listenerPID: Int32? = nil,
        lastExitCode: Int32? = nil,
        currentJob: RunnerJobInfo? = nil,
        lastCompletedJob: RunnerJobInfo? = nil,
        lastActivityAt: Date? = nil,
        lastFailureMessage: String? = nil,
        lastFailureAt: Date? = nil,
        restartCount: Int = 0,
        runnerVersion: String? = nil,
        diagnosticLogURLs: [URL] = []
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.directoryName = directoryName
        self.registration = registration
        self.hasValidBinaries = hasValidBinaries
        self.hasCredentials = hasCredentials
        self.serviceConfig = serviceConfig
        self.status = status
        self.statusExplanation = statusExplanation
        self.servicePID = servicePID
        self.listenerPID = listenerPID
        self.lastExitCode = lastExitCode
        self.currentJob = currentJob
        self.lastCompletedJob = lastCompletedJob
        self.lastActivityAt = lastActivityAt
        self.lastFailureMessage = lastFailureMessage
        self.lastFailureAt = lastFailureAt
        self.restartCount = restartCount
        self.runnerVersion = runnerVersion
        self.diagnosticLogURLs = diagnosticLogURLs
    }

    /// Registered runner name if available, otherwise falls back to directory name.
    public var displayName: String {
        registration?.agentName ?? directoryName
    }

    /// Primary PID to display in the UI.
    public var displayPID: Int32? {
        listenerPID ?? servicePID
    }

    /// Directory containing diagnostic logs (`_diag`).
    public var diagDirectoryURL: URL {
        directoryURL.appendingPathComponent("_diag", isDirectory: true)
    }
}
