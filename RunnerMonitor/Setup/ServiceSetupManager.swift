import Foundation

/// Action proposed for a single runner during service supervision setup.
public enum ServiceSetupActionKind: String, Codable, Sendable, Equatable {
    /// Service is already properly configured with KeepAlive, RunAtLoad, and ThrottleInterval; no changes needed.
    case none = "Already configured (no changes required)"
    /// Runner is registered, but LaunchAgent service is not installed yet.
    case installAndConfigure = "Install LaunchAgent and configure automatic recovery"
    /// LaunchAgent plist exists, but is missing KeepAlive/ThrottleInterval or needs repair.
    case updateSupervisionPolicy = "Update LaunchAgent supervision policy (KeepAlive + ThrottleInterval)"
    /// Existing service configuration is broken (e.g. missing plist or wrong WorkingDirectory) and needs repair.
    case repairInvalidConfiguration = "Repair invalid service configuration"
    /// Runner is not registered with GitHub yet; cannot install service.
    case skipNotConfigured = "Skip (runner registration is incomplete)"
}

public struct RunnerServiceSetupPlanItem: Identifiable, Sendable, Equatable {
    public var id: String { runnerDirectoryURL.path }
    public let runnerName: String
    public let runnerDirectoryURL: URL
    public let serviceName: String
    public let targetPlistURL: URL
    public let action: ServiceSetupActionKind
    public let isCurrentlyRunning: Bool
    public let isCurrentlyBusy: Bool
    public let explanation: String
    public let rollbackInstructions: String

    public init(
        runnerName: String,
        runnerDirectoryURL: URL,
        serviceName: String,
        targetPlistURL: URL,
        action: ServiceSetupActionKind,
        isCurrentlyRunning: Bool,
        isCurrentlyBusy: Bool,
        explanation: String,
        rollbackInstructions: String
    ) {
        self.runnerName = runnerName
        self.runnerDirectoryURL = runnerDirectoryURL
        self.serviceName = serviceName
        self.targetPlistURL = targetPlistURL
        self.action = action
        self.isCurrentlyRunning = isCurrentlyRunning
        self.isCurrentlyBusy = isCurrentlyBusy
        self.explanation = explanation
        self.rollbackInstructions = rollbackInstructions
    }
}

public struct ServiceSetupBackup: Sendable, Equatable {
    public let runnerDirectoryURL: URL
    public let serviceName: String
    public let backupDirectoryURL: URL
    public let backedUpPlistURL: URL?
    public let backedUpServiceFileURL: URL?
}

/// Manages discovery, planning, idempotent LaunchAgent plist preparation, validation, backup, and rollback
/// for official GitHub Actions macOS runner services.
public struct ServiceSetupManager: Sendable {
    public let discovery: RunnerDiscovery
    public let launchdReader: any LaunchdStatusReading
    public let logReader: RunnerLogReader
    public let statusResolver: RunnerStatusResolver
    public let launchAgentsDirectoryURL: URL
    public let logsRootDirectoryURL: URL
    public let userName: String
    public let homeDirectoryURL: URL

    public init(
        discovery: RunnerDiscovery = RunnerDiscovery(),
        launchdReader: any LaunchdStatusReading = LaunchdStatusReader(),
        logReader: RunnerLogReader = RunnerLogReader(),
        statusResolver: RunnerStatusResolver = RunnerStatusResolver(),
        launchAgentsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        logsRootDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true),
        userName: String = NSUserName(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.discovery = discovery
        self.launchdReader = launchdReader
        self.logReader = logReader
        self.statusResolver = statusResolver
        self.launchAgentsDirectoryURL = launchAgentsDirectoryURL
        self.logsRootDirectoryURL = logsRootDirectoryURL
        self.userName = userName
        self.homeDirectoryURL = homeDirectoryURL
    }

    // MARK: - Step 1–5: Build Read-Only Setup Plan

    public func buildSetupPlan(in rootURL: URL) -> [RunnerServiceSetupPlanItem] {
        let candidates = discovery.discoverRunners(in: rootURL)
        var items: [RunnerServiceSetupPlanItem] = []

        for candidate in candidates {
            let runnerName = candidate.registration?.agentName ?? candidate.directoryName

            if candidate.escapedRootBoundary || !candidate.configurationErrors.isEmpty || candidate.registration == nil {
                let err = candidate.configurationErrors.first ?? "Runner registration is incomplete."
                let fallbackSvc = candidate.serviceConfig?.serviceName ?? "actions.runner.\(candidate.directoryName)"
                let plistURL = launchAgentsDirectoryURL.appendingPathComponent("\(fallbackSvc).plist")
                items.append(
                    RunnerServiceSetupPlanItem(
                        runnerName: runnerName,
                        runnerDirectoryURL: candidate.directoryURL,
                        serviceName: fallbackSvc,
                        targetPlistURL: plistURL,
                        action: .skipNotConfigured,
                        isCurrentlyRunning: false,
                        isCurrentlyBusy: false,
                        explanation: err,
                        rollbackInstructions: "No changes will be made to \(runnerName)."
                    )
                )
                continue
            }

            let svcName = candidate.serviceConfig?.serviceName
                ?? Self.deriveDefaultServiceName(from: candidate)
            let plistURL = candidate.serviceConfig?.plistURL
                ?? launchAgentsDirectoryURL.appendingPathComponent("\(svcName).plist")

            let launchdSnap = launchdReader.readStatus(for: svcName)
            let logSnap = logReader.readSnapshot(for: candidate)
            let resolved = statusResolver.resolve(
                candidate: candidate,
                launchdSnapshot: launchdSnap,
                logSnapshot: logSnap
            ).runner

            let isRunning = launchdSnap.isRunning
            let isBusy = resolved.status == .busy

            let rollbackCmd = "launchctl unload \"\(plistURL.path)\" && (cd \"\(candidate.directoryURL.path)\" && ./svc.sh uninstall)"

            if let svcConfig = candidate.serviceConfig {
                if !svcConfig.validationIssues.isEmpty {
                    items.append(
                        RunnerServiceSetupPlanItem(
                            runnerName: runnerName,
                            runnerDirectoryURL: candidate.directoryURL,
                            serviceName: svcName,
                            targetPlistURL: plistURL,
                            action: .repairInvalidConfiguration,
                            isCurrentlyRunning: isRunning,
                            isCurrentlyBusy: isBusy,
                            explanation: "Existing service configuration has validation issues: \(svcConfig.validationIssues.joined(separator: " "))",
                            rollbackInstructions: rollbackCmd
                        )
                    )
                } else if svcConfig.isServiceFilePresent && svcConfig.isPlistPresent {
                    if svcConfig.runAtLoad && svcConfig.keepAlive && svcConfig.throttleInterval == 30 {
                        items.append(
                            RunnerServiceSetupPlanItem(
                                runnerName: runnerName,
                                runnerDirectoryURL: candidate.directoryURL,
                                serviceName: svcName,
                                targetPlistURL: plistURL,
                                action: .none,
                                isCurrentlyRunning: isRunning,
                                isCurrentlyBusy: isBusy,
                                explanation: "LaunchAgent \(svcName) is already installed with RunAtLoad, KeepAlive, and ThrottleInterval=30.",
                                rollbackInstructions: rollbackCmd
                            )
                        )
                    } else {
                        items.append(
                            RunnerServiceSetupPlanItem(
                                runnerName: runnerName,
                                runnerDirectoryURL: candidate.directoryURL,
                                serviceName: svcName,
                                targetPlistURL: plistURL,
                                action: .updateSupervisionPolicy,
                                isCurrentlyRunning: isRunning,
                                isCurrentlyBusy: isBusy,
                                explanation: "Update \(plistURL.lastPathComponent) to ensure RunAtLoad=true, KeepAlive=true, and ThrottleInterval=30 while preserving official runner fields.",
                                rollbackInstructions: rollbackCmd
                            )
                        )
                    }
                } else {
                    items.append(
                        RunnerServiceSetupPlanItem(
                            runnerName: runnerName,
                            runnerDirectoryURL: candidate.directoryURL,
                            serviceName: svcName,
                            targetPlistURL: plistURL,
                            action: .installAndConfigure,
                            isCurrentlyRunning: isRunning,
                            isCurrentlyBusy: isBusy,
                            explanation: "Create runsvc.sh, .service, log directory, and LaunchAgent \(plistURL.path) with RunAtLoad=true, KeepAlive=true, ThrottleInterval=30.",
                            rollbackInstructions: rollbackCmd
                        )
                    )
                }
            } else {
                items.append(
                    RunnerServiceSetupPlanItem(
                        runnerName: runnerName,
                        runnerDirectoryURL: candidate.directoryURL,
                        serviceName: svcName,
                        targetPlistURL: plistURL,
                        action: .installAndConfigure,
                        isCurrentlyRunning: isRunning,
                        isCurrentlyBusy: isBusy,
                        explanation: "Install LaunchAgent \(plistURL.path) with RunAtLoad=true, KeepAlive=true, ThrottleInterval=30.",
                        rollbackInstructions: rollbackCmd
                    )
                )
            }
        }

        return items
    }

    // MARK: - Step 7–10: Apply Configuration Safely (Filesystem Preparation & Validation)

    /// Prepares or updates the runner's `runsvc.sh`, `.service`, log folder, and LaunchAgent `.plist`
    /// idempotently, creating backups before modifying existing files.
    /// Does not stop a busy runner unless `allowStoppingBusyRunner` is explicitly true.
    @discardableResult
    public func applyConfiguration(
        for item: RunnerServiceSetupPlanItem,
        backupRootURL: URL,
        allowStoppingBusyRunner: Bool = false,
        startOrReloadLaunchdService: Bool = false
    ) throws -> ServiceSetupBackup? {
        if item.action == .skipNotConfigured {
            return nil
        }

        if item.isCurrentlyBusy && !allowStoppingBusyRunner {
            throw NSError(
                domain: "ServiceSetupManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to modify \(item.runnerName) while it is actively executing a CI job without explicit approval."]
            )
        }

        if item.action == .none {
            if startOrReloadLaunchdService && !item.isCurrentlyRunning {
                try startLaunchdService(plistURL: item.targetPlistURL)
            }
            return nil
        }

        let fileManager = FileManager.default
        let runnerDir = item.runnerDirectoryURL
        let serviceFileURL = runnerDir.appendingPathComponent(".service")
        let plistURL = item.targetPlistURL

        // 1. Back up existing .plist and .service if present
        let backupDir = backupRootURL.appendingPathComponent(item.serviceName, isDirectory: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var backedUpPlistURL: URL?
        if fileManager.fileExists(atPath: plistURL.path) {
            let dest = backupDir.appendingPathComponent(plistURL.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: plistURL, to: dest)
            backedUpPlistURL = dest
        }

        var backedUpServiceFileURL: URL?
        if fileManager.fileExists(atPath: serviceFileURL.path) {
            let dest = backupDir.appendingPathComponent(".service.bak")
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: serviceFileURL, to: dest)
            backedUpServiceFileURL = dest
        }

        let backup = ServiceSetupBackup(
            runnerDirectoryURL: runnerDir,
            serviceName: item.serviceName,
            backupDirectoryURL: backupDir,
            backedUpPlistURL: backedUpPlistURL,
            backedUpServiceFileURL: backedUpServiceFileURL
        )

        // 2. Ensure runsvc.sh exists and is executable in runner root (mirroring official svc.sh install)
        let binRunsvcURL = runnerDir.appendingPathComponent("bin/runsvc.sh")
        let rootRunsvcURL = runnerDir.appendingPathComponent("runsvc.sh")
        if !fileManager.fileExists(atPath: rootRunsvcURL.path),
           fileManager.fileExists(atPath: binRunsvcURL.path) {
            try fileManager.copyItem(at: binRunsvcURL, to: rootRunsvcURL)
        }
        if fileManager.fileExists(atPath: rootRunsvcURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootRunsvcURL.path)
        }

        // 3. Ensure ~/Library/Logs/<SVC_NAME> and ~/Library/LaunchAgents exist
        let serviceLogDir = logsRootDirectoryURL.appendingPathComponent(item.serviceName, isDirectory: true)
        try fileManager.createDirectory(at: serviceLogDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 4. Construct or merge LaunchAgent plist dictionary preserving official runner fields
        var plistDict = loadOrRenderBasePlist(for: item, runnerDir: runnerDir, serviceLogDir: serviceLogDir)
        plistDict["Label"] = item.serviceName
        plistDict["ProgramArguments"] = [rootRunsvcURL.path]
        plistDict["WorkingDirectory"] = runnerDir.path
        plistDict["RunAtLoad"] = true
        plistDict["KeepAlive"] = true
        plistDict["ThrottleInterval"] = 30

        if plistDict["StandardOutPath"] == nil {
            plistDict["StandardOutPath"] = serviceLogDir.appendingPathComponent("stdout.log").path
        }
        if plistDict["StandardErrorPath"] == nil {
            plistDict["StandardErrorPath"] = serviceLogDir.appendingPathComponent("stderr.log").path
        }
        var envVars = (plistDict["EnvironmentVariables"] as? [String: String]) ?? [:]
        envVars["ACTIONS_RUNNER_SVC"] = "1"
        plistDict["EnvironmentVariables"] = envVars
        if plistDict["ProcessType"] == nil {
            plistDict["ProcessType"] = "Interactive"
        }
        if plistDict["SessionCreate"] == nil {
            plistDict["SessionCreate"] = true
        }

        // 5. Serialize and validate plist before writing
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try Self.validatePlistData(plistData, expectedServiceName: item.serviceName, expectedWorkingDir: runnerDir.path)

        try plistData.write(to: plistURL, options: .atomic)

        // 6. Write .service file containing the authoritative plist path
        let serviceFileContent = plistURL.path + "\n"
        try serviceFileContent.write(to: serviceFileURL, atomically: true, encoding: .utf8)

        // 7. Optionally reload/start service via /bin/launchctl
        if startOrReloadLaunchdService {
            if item.isCurrentlyRunning {
                _ = try? runLaunchctl(arguments: ["unload", plistURL.path])
            }
            try startLaunchdService(plistURL: plistURL)
        }

        return backup
    }

    public func startLaunchdService(plistURL: URL) throws {
        let result = try runLaunchctl(arguments: ["load", "-w", plistURL.path])
        if result.exitCode != 0 {
            throw NSError(
                domain: "ServiceSetupManager",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Failed to load LaunchAgent \(plistURL.lastPathComponent): \(result.stderr)"]
            )
        }
    }

    public func rollback(using backup: ServiceSetupBackup) throws {
        let fileManager = FileManager.default
        let plistURL = launchAgentsDirectoryURL.appendingPathComponent("\(backup.serviceName).plist")
        let serviceFileURL = backup.runnerDirectoryURL.appendingPathComponent(".service")

        if let backedUpPlist = backup.backedUpPlistURL, fileManager.fileExists(atPath: backedUpPlist.path) {
            if fileManager.fileExists(atPath: plistURL.path) {
                try fileManager.removeItem(at: plistURL)
            }
            try fileManager.copyItem(at: backedUpPlist, to: plistURL)
        } else if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }

        if let backedUpService = backup.backedUpServiceFileURL, fileManager.fileExists(atPath: backedUpService.path) {
            if fileManager.fileExists(atPath: serviceFileURL.path) {
                try fileManager.removeItem(at: serviceFileURL)
            }
            try fileManager.copyItem(at: backedUpService, to: serviceFileURL)
        } else if fileManager.fileExists(atPath: serviceFileURL.path) {
            try fileManager.removeItem(at: serviceFileURL)
        }
    }

    public static func validatePlistData(
        _ data: Data,
        expectedServiceName: String,
        expectedWorkingDir: String
    ) throws {
        guard let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "ServiceSetupManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Generated LaunchAgent plist is not a valid dictionary."])
        }
        guard (obj["Label"] as? String) == expectedServiceName else {
            throw NSError(domain: "ServiceSetupManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "LaunchAgent Label does not match expected service name."])
        }
        guard (obj["WorkingDirectory"] as? String) == expectedWorkingDir else {
            throw NSError(domain: "ServiceSetupManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "LaunchAgent WorkingDirectory does not match runner directory."])
        }
        guard (obj["RunAtLoad"] as? Bool) == true, (obj["KeepAlive"] as? Bool) == true else {
            throw NSError(domain: "ServiceSetupManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "LaunchAgent supervision keys (RunAtLoad / KeepAlive) are missing."])
        }
        guard (obj["ThrottleInterval"] as? Int) == 30 else {
            throw NSError(domain: "ServiceSetupManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "LaunchAgent ThrottleInterval is not set to 30."])
        }
    }

    // MARK: - Helpers

    private func runLaunchctl(arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func loadOrRenderBasePlist(
        for item: RunnerServiceSetupPlanItem,
        runnerDir: URL,
        serviceLogDir: URL
    ) -> [String: Any] {
        // 1. If existing valid plist exists, preserve its fields
        if let existingData = try? Data(contentsOf: item.targetPlistURL),
           let existingDict = try? PropertyListSerialization.propertyList(from: existingData, options: [], format: nil) as? [String: Any] {
            return existingDict
        }

        // 2. Otherwise render from bin/actions.runner.plist.template if available
        let templateURL = runnerDir.appendingPathComponent("bin/actions.runner.plist.template")
        if let templateText = try? String(contentsOf: templateURL, encoding: .utf8) {
            let rendered = templateText
                .replacingOccurrences(of: "{{User}}", with: userName)
                .replacingOccurrences(of: "{{SvcName}}", with: item.serviceName)
                .replacingOccurrences(of: "{{RunnerRoot}}", with: runnerDir.path)
                .replacingOccurrences(of: "{{UserHome}}", with: homeDirectoryURL.path)
            if let renderedData = rendered.data(using: .utf8),
               let dict = try? PropertyListSerialization.propertyList(from: renderedData, options: [], format: nil) as? [String: Any] {
                return dict
            }
        }

        // 3. Fallback standard dictionary matching official GitHub runner template
        return [
            "Label": item.serviceName,
            "ProgramArguments": [runnerDir.appendingPathComponent("runsvc.sh").path],
            "UserName": userName,
            "WorkingDirectory": runnerDir.path,
            "RunAtLoad": true,
            "StandardOutPath": serviceLogDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": serviceLogDir.appendingPathComponent("stderr.log").path,
            "EnvironmentVariables": ["ACTIONS_RUNNER_SVC": "1"],
            "ProcessType": "Interactive",
            "SessionCreate": true
        ]
    }

    public static func deriveDefaultServiceName(from candidate: DiscoveredRunnerCandidate) -> String {
        let repoPart = candidate.registration?.repositoryDisplayName?
            .replacingOccurrences(of: "/", with: "-") ?? "local"
        let agentPart = (candidate.registration?.agentName ?? candidate.directoryName)
            .replacingOccurrences(of: " ", with: "_")
        return "actions.runner.\(repoPart).\(agentPart)"
    }
}
