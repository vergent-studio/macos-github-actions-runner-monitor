import Foundation
import AppKit
import Observation
import ServiceManagement

/// Central observable state for the Runner Monitor application.
@MainActor
@Observable
public final class AppState {
    // MARK: - Observable State

    public var runners: [Runner] = []
    public var aggregateStatus: AggregateRunnerStatus = .unknown
    public var recentEvents: [RunnerEvent] = []
    public var selectedRunnerId: String?
    public var selectedRunnerLogs: [RunnerLogEntry] = []
    public var isRefreshing: Bool = false
    public var lastRefreshedAt: Date?
    public var lastRefreshDurationMs: Double?
    public var setupPlanItems: [RunnerServiceSetupPlanItem] = []
    public var setupStatusMessage: String?

    public var selectedRunner: Runner? {
        guard let selectedRunnerId else { return nil }
        return runners.first(where: { $0.id == selectedRunnerId })
    }

    public var summarySubtitle: String {
        guard !runners.isEmpty else {
            return "No runners discovered"
        }
        let idleCount = runners.filter { $0.status == .idle }.count
        let busyCount = runners.filter { $0.status == .busy }.count
        let attentionCount = runners.count - idleCount - busyCount
        var parts: [String] = []
        if busyCount > 0 { parts.append("\(busyCount) busy") }
        if idleCount > 0 { parts.append("\(idleCount) idle") }
        if attentionCount > 0 { parts.append("\(attentionCount) need attention") }
        return parts.joined(separator: " · ")
    }

    // MARK: - User Preferences (Persisted via UserDefaults)

    public var discoveryRootPath: String {
        didSet {
            userDefaults.set(discoveryRootPath, forKey: Keys.discoveryRootPath)
            triggerImmediateRefresh()
        }
    }

    public var refreshIntervalSeconds: Double {
        didSet {
            let clamped = max(2.0, min(60.0, refreshIntervalSeconds))
            if refreshIntervalSeconds != clamped {
                refreshIntervalSeconds = clamped
                return
            }
            userDefaults.set(refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds)
            restartRefreshLoop()
        }
    }

    public var maxDisplayedLogLines: Int {
        didSet {
            let clamped = max(50, min(2000, maxDisplayedLogLines))
            if maxDisplayedLogLines != clamped {
                maxDisplayedLogLines = clamped
                return
            }
            userDefaults.set(maxDisplayedLogLines, forKey: Keys.maxDisplayedLogLines)
        }
    }

    public var notifyOnFailures: Bool {
        didSet {
            userDefaults.set(notifyOnFailures, forKey: Keys.notifyOnFailures)
            if notifyOnFailures {
                notificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    public var notifyOnRestarts: Bool {
        didSet {
            userDefaults.set(notifyOnRestarts, forKey: Keys.notifyOnRestarts)
            if notifyOnRestarts {
                notificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    public var notifyOnJobs: Bool {
        didSet {
            userDefaults.set(notifyOnJobs, forKey: Keys.notifyOnJobs)
            if notifyOnJobs {
                notificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    public var launchAtLogin: Bool {
        didSet {
            userDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLoginRegistration(enabled: launchAtLogin)
        }
    }

    // MARK: - Dependencies

    private let userDefaults: UserDefaults
    private let discovery: RunnerDiscovery
    private let launchdReader: any LaunchdStatusReading
    private let logReader: RunnerLogReader
    private let statusResolver: RunnerStatusResolver
    private let notificationManager: NotificationManager
    private let setupManager: ServiceSetupManager

    private var refreshLoopTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let maxRecentEvents: Int = 50

    private enum Keys {
        static let discoveryRootPath = "RunnerMonitor.discoveryRootPath"
        static let refreshIntervalSeconds = "RunnerMonitor.refreshIntervalSeconds"
        static let maxDisplayedLogLines = "RunnerMonitor.maxDisplayedLogLines"
        static let notifyOnFailures = "RunnerMonitor.notifyOnFailures"
        static let notifyOnRestarts = "RunnerMonitor.notifyOnRestarts"
        static let notifyOnJobs = "RunnerMonitor.notifyOnJobs"
        static let launchAtLogin = "RunnerMonitor.launchAtLogin"
    }

    public init(
        userDefaults: UserDefaults = .standard,
        discovery: RunnerDiscovery = RunnerDiscovery(),
        launchdReader: any LaunchdStatusReading = LaunchdStatusReader(),
        logReader: RunnerLogReader = RunnerLogReader(),
        statusResolver: RunnerStatusResolver = RunnerStatusResolver(),
        notificationManager: NotificationManager = .shared,
        autoStartLoop: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.discovery = discovery
        self.launchdReader = launchdReader
        self.logReader = logReader
        self.statusResolver = statusResolver
        self.notificationManager = notificationManager
        self.setupManager = ServiceSetupManager(
            discovery: discovery,
            launchdReader: launchdReader,
            logReader: logReader,
            statusResolver: statusResolver
        )

        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners", isDirectory: true).path

        self.discoveryRootPath = userDefaults.string(forKey: Keys.discoveryRootPath) ?? defaultRoot

        let storedInterval = userDefaults.double(forKey: Keys.refreshIntervalSeconds)
        self.refreshIntervalSeconds = storedInterval > 0 ? storedInterval : 5.0

        let storedMaxLines = userDefaults.integer(forKey: Keys.maxDisplayedLogLines)
        self.maxDisplayedLogLines = storedMaxLines > 0 ? storedMaxLines : 300

        self.notifyOnFailures = userDefaults.object(forKey: Keys.notifyOnFailures) as? Bool ?? true
        self.notifyOnRestarts = userDefaults.object(forKey: Keys.notifyOnRestarts) as? Bool ?? true
        self.notifyOnJobs = userDefaults.object(forKey: Keys.notifyOnJobs) as? Bool ?? false
        self.launchAtLogin = userDefaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        if autoStartLoop {
            setupSleepWakeObserver()
            restartRefreshLoop()
        }
    }

    // MARK: - Selection & Logs

    public func selectRunner(_ runner: Runner?) {
        selectedRunnerId = runner?.id
        if let runner {
            reloadLogs(for: runner)
        } else {
            selectedRunnerLogs = []
        }
    }

    public func reloadLogsForSelectedRunner() {
        guard let runner = selectedRunner else { return }
        reloadLogs(for: runner)
    }

    private func reloadLogs(for runner: Runner) {
        let maxLines = maxDisplayedLogLines
        let logReaderRef = self.logReader
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                logReaderRef.readLogEntries(for: runner, maxEntries: maxLines)
            }.value
            if self.selectedRunnerId == runner.id {
                self.selectedRunnerLogs = entries
            }
        }
    }

    // MARK: - Refresh Control

    public func triggerImmediateRefresh() {
        Task {
            await performRefresh()
        }
    }

    public func restartRefreshLoop() {
        refreshLoopTask?.cancel()
        let interval = refreshIntervalSeconds
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            while !Task.isCancelled {
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { break }
                await self.performRefresh()
            }
        }
    }

    public func performRefresh() async {
        if isRefreshing { return }
        isRefreshing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        let rootURL = URL(fileURLWithPath: (discoveryRootPath as NSString).expandingTildeInPath, isDirectory: true)
        let previousByID = Dictionary(uniqueKeysWithValues: runners.map { ($0.id, $0) })
        let currentSelectedId = selectedRunnerId
        let maxLines = maxDisplayedLogLines

        let discoveryRef = self.discovery
        let launchdRef = self.launchdReader
        let logReaderRef = self.logReader
        let resolverRef = self.statusResolver

        let (outputs, updatedLogs) = await Task.detached(priority: .utility) { () -> ([RunnerResolutionOutput], [RunnerLogEntry]?) in
            let candidates = discoveryRef.discoverRunners(in: rootURL)
            var resolvedOutputs: [RunnerResolutionOutput] = []
            var logsForSelected: [RunnerLogEntry]?

            for candidate in candidates {
                let launchdSnap: LaunchdServiceSnapshot?
                if let svcName = candidate.serviceConfig?.serviceName {
                    launchdSnap = launchdRef.readStatus(for: svcName)
                } else {
                    launchdSnap = nil
                }

                let logSnap = logReaderRef.readSnapshot(for: candidate)
                let previous = previousByID[candidate.directoryURL.path]

                let output = resolverRef.resolve(
                    candidate: candidate,
                    launchdSnapshot: launchdSnap,
                    logSnapshot: logSnap,
                    previousRunner: previous
                )
                resolvedOutputs.append(output)

                if let currentSelectedId, output.runner.id == currentSelectedId {
                    logsForSelected = logReaderRef.readLogEntries(for: output.runner, maxEntries: maxLines)
                }
            }

            return (resolvedOutputs, logsForSelected)
        }.value

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        self.runners = outputs.map { $0.runner }
        self.aggregateStatus = AggregateRunnerStatus.resolve(from: self.runners)
        self.lastRefreshedAt = Date()
        self.lastRefreshDurationMs = elapsedMs

        if let updatedLogs {
            self.selectedRunnerLogs = updatedLogs
        }

        let newEvents = outputs.flatMap { $0.emittedEvents }
        if !newEvents.isEmpty {
            let combined = (newEvents + self.recentEvents)
                .sorted(by: { $0.timestamp > $1.timestamp })
            self.recentEvents = Array(combined.prefix(maxRecentEvents))
            for event in newEvents {
                notificationManager.postNotification(
                    for: event,
                    notifyOnFailures: notifyOnFailures,
                    notifyOnRestarts: notifyOnRestarts,
                    notifyOnJobs: notifyOnJobs
                )
            }
        }

        isRefreshing = false
    }

    // MARK: - Service Supervision Setup (Phase 3)

    public func refreshSetupPlan() {
        let rootURL = URL(fileURLWithPath: (discoveryRootPath as NSString).expandingTildeInPath, isDirectory: true)
        let setupRef = self.setupManager
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                setupRef.buildSetupPlan(in: rootURL)
            }.value
            self.setupPlanItems = plan
        }
    }

    public func applyServiceSupervisionSetup(startServices: Bool = true) {
        let rootURL = URL(fileURLWithPath: (discoveryRootPath as NSString).expandingTildeInPath, isDirectory: true)
        let backupRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RunnerMonitor/Backups", isDirectory: true)
        let setupRef = self.setupManager

        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> String in
                let plan = setupRef.buildSetupPlan(in: rootURL)
                var appliedCount = 0
                for item in plan {
                    do {
                        _ = try setupRef.applyConfiguration(
                            for: item,
                            backupRootURL: backupRoot,
                            allowStoppingBusyRunner: false,
                            startOrReloadLaunchdService: startServices
                        )
                        if item.action != .skipNotConfigured {
                            appliedCount += 1
                        }
                    } catch {
                        return "Setup failed for \(item.runnerName): \(error.localizedDescription)"
                    }
                }
                return "Supervision configured for \(appliedCount) runner(s)."
            }.value

            self.setupStatusMessage = message
            self.refreshSetupPlan()
            await self.performRefresh()
        }
    }

    // MARK: - Private Helpers

    private func setupSleepWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerImmediateRefresh()
            }
        }
    }

    private func updateLaunchAtLoginRegistration(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Best-effort registration; ad-hoc or unbundled test runs may not support SMAppService
        }
    }
}
