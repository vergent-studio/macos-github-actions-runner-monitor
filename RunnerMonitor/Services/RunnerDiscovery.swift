import Foundation

/// Intermediate discovery result for a single runner candidate directory before status resolution.
public struct DiscoveredRunnerCandidate: Sendable, Equatable {
    public let id: String
    public let directoryURL: URL
    public let directoryName: String
    public let registration: RunnerRegistration?
    public let hasValidBinaries: Bool
    public let hasCredentials: Bool
    public let serviceConfig: RunnerServiceConfig?
    public let diagnosticLogURLs: [URL]
    public let configurationErrors: [String]
    public let escapedRootBoundary: Bool

    public init(
        id: String,
        directoryURL: URL,
        directoryName: String,
        registration: RunnerRegistration? = nil,
        hasValidBinaries: Bool = false,
        hasCredentials: Bool = false,
        serviceConfig: RunnerServiceConfig? = nil,
        diagnosticLogURLs: [URL] = [],
        configurationErrors: [String] = [],
        escapedRootBoundary: Bool = false
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.directoryName = directoryName
        self.registration = registration
        self.hasValidBinaries = hasValidBinaries
        self.hasCredentials = hasCredentials
        self.serviceConfig = serviceConfig
        self.diagnosticLogURLs = diagnosticLogURLs
        self.configurationErrors = configurationErrors
        self.escapedRootBoundary = escapedRootBoundary
    }
}

/// Discovers and validates official GitHub Actions runner installations on the local filesystem.
/// Strictly read-only: never executes scripts or modifies files.
public struct RunnerDiscovery: Sendable {
    public let directoryPrefix: String
    public let launchAgentsDirectoryURL: URL

    public init(
        directoryPrefix: String = "runner-",
        launchAgentsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    ) {
        self.directoryPrefix = directoryPrefix
        self.launchAgentsDirectoryURL = launchAgentsDirectoryURL
    }

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners", isDirectory: true)
    }

    /// Discovers immediate child directories matching `directoryPrefix` under `rootURL`.
    public func discoverRunners(in rootURL: URL) -> [DiscoveredRunnerCandidate] {
        let fileManager = FileManager.default
        let canonicalRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalRootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let matchingDirs = children
            .filter { $0.lastPathComponent.hasPrefix(directoryPrefix) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var results: [DiscoveredRunnerCandidate] = []
        for candidateURL in matchingDirs {
            if let candidate = inspectCandidate(at: candidateURL, canonicalRootURL: canonicalRootURL) {
                results.append(candidate)
            }
        }
        return results
    }

    public func inspectCandidate(at candidateURL: URL, canonicalRootURL: URL) -> DiscoveredRunnerCandidate? {
        let fileManager = FileManager.default
        let dirName = candidateURL.lastPathComponent
        let resolvedCandidateURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()

        // Ensure it is a directory (or symlink to directory)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedCandidateURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Security boundary check: candidate must not escape canonicalRootURL via symlink
        if !Self.isSubpath(resolvedCandidateURL, of: canonicalRootURL) {
            return DiscoveredRunnerCandidate(
                id: candidateURL.standardizedFileURL.path,
                directoryURL: candidateURL.standardizedFileURL,
                directoryName: dirName,
                configurationErrors: ["Runner directory symlink escapes the configured discovery root."],
                escapedRootBoundary: true
            )
        }

        var configErrors: [String] = []

        // Check required runner scripts (without executing them)
        let configScriptURL = resolvedCandidateURL.appendingPathComponent("config.sh")
        let runScriptURL = resolvedCandidateURL.appendingPathComponent("run.sh")
        let hasConfigScript = Self.isSafeRegularFile(configScriptURL, inside: resolvedCandidateURL)
        let hasRunScript = Self.isSafeRegularFile(runScriptURL, inside: resolvedCandidateURL)
        let hasValidBinaries = hasConfigScript && hasRunScript
        if !hasValidBinaries {
            configErrors.append("Missing official runner scripts (config.sh or run.sh).")
        }

        // Check .credentials presence (do not read contents)
        let credentialsURL = resolvedCandidateURL.appendingPathComponent(".credentials")
        let hasCredentials = Self.isSafeRegularFile(credentialsURL, inside: resolvedCandidateURL)

        // Parse .runner registration file
        let runnerFileURL = resolvedCandidateURL.appendingPathComponent(".runner")
        var registration: RunnerRegistration?
        if fileManager.fileExists(atPath: runnerFileURL.path) {
            if Self.isSafeRegularFile(runnerFileURL, inside: resolvedCandidateURL) {
                switch Self.parseRunnerRegistration(at: runnerFileURL) {
                case .success(let reg):
                    registration = reg
                    if reg.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        configErrors.append(".runner configuration has an empty agentName.")
                    }
                case .failure(let error):
                    configErrors.append("Malformed .runner configuration: \(error.localizedDescription)")
                }
            } else {
                configErrors.append(".runner file escapes the runner directory boundary.")
            }
        } else {
            configErrors.append("Runner is not registered (.runner file missing).")
        }

        if registration != nil && !hasCredentials {
            configErrors.append("Runner credentials file (.credentials) is missing.")
        }

        // Discover service configuration (.service, svc.sh, and LaunchAgent plist)
        let serviceConfig = inspectServiceConfig(in: resolvedCandidateURL)

        // Discover diagnostic log files in _diag/
        let diagURLs = discoverDiagnosticLogs(in: resolvedCandidateURL)

        return DiscoveredRunnerCandidate(
            id: resolvedCandidateURL.path,
            directoryURL: resolvedCandidateURL,
            directoryName: dirName,
            registration: registration,
            hasValidBinaries: hasValidBinaries,
            hasCredentials: hasCredentials,
            serviceConfig: serviceConfig,
            diagnosticLogURLs: diagURLs,
            configurationErrors: configErrors,
            escapedRootBoundary: false
        )
    }

    // MARK: - Helpers

    public static func parseRunnerRegistration(at url: URL) -> Result<RunnerRegistration, Error> {
        do {
            var data = try Data(contentsOf: url, options: [.mappedIfSafe])
            // Strip UTF-8 BOM (EF BB BF) if present, as official GitHub runner writes .runner with UTF-8 BOM
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                data.removeFirst(3)
            }
            let decoder = JSONDecoder()
            let reg = try decoder.decode(RunnerRegistration.self, from: data)
            return .success(reg)
        } catch {
            return .failure(error)
        }
    }

    private func inspectServiceConfig(in runnerDirURL: URL) -> RunnerServiceConfig? {
        let fileManager = FileManager.default
        let serviceFileURL = runnerDirURL.appendingPathComponent(".service")
        let svcScriptURL = runnerDirURL.appendingPathComponent("svc.sh")

        var isServiceFilePresent = false
        var serviceFilePlistURL: URL?
        var validationIssues: [String] = []

        if fileManager.fileExists(atPath: serviceFileURL.path) {
            if Self.isSafeRegularFile(serviceFileURL, inside: runnerDirURL),
               let rawContent = try? String(contentsOf: serviceFileURL, encoding: .utf8) {
                isServiceFilePresent = true
                let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let expanded = (trimmed as NSString).expandingTildeInPath
                    serviceFilePlistURL = URL(fileURLWithPath: expanded).standardizedFileURL
                } else {
                    validationIssues.append(".service file is empty.")
                }
            } else {
                validationIssues.append(".service file is inaccessible or escapes runner directory.")
            }
        }

        // Also extract SVC_NAME from svc.sh if present (pure text inspection, never executed)
        var svcScriptServiceName: String?
        if Self.isSafeRegularFile(svcScriptURL, inside: runnerDirURL),
           let svcText = try? String(contentsOf: svcScriptURL, encoding: .utf8) {
            svcScriptServiceName = Self.extractServiceNameFromSvcScript(svcText)
        }

        // Determine candidate plist URL
        let candidatePlistURL: URL? = serviceFilePlistURL ?? svcScriptServiceName.map {
            launchAgentsDirectoryURL.appendingPathComponent("\($0).plist")
        }

        var isPlistPresent = false
        var plistLabel: String?
        var standardOutURL: URL?
        var standardErrorURL: URL?
        var workingDirectoryURL: URL?
        var programArguments: [String] = []
        var runAtLoad = false
        var keepAlive = false
        var throttleInterval: Int?

        if let plistURL = candidatePlistURL {
            if fileManager.fileExists(atPath: plistURL.path) {
                isPlistPresent = true
                if let plistData = try? Data(contentsOf: plistURL),
                   let plistObj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
                   let dict = plistObj as? [String: Any] {
                    plistLabel = dict["Label"] as? String
                    if let outPath = dict["StandardOutPath"] as? String {
                        standardOutURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
                    }
                    if let errPath = dict["StandardErrorPath"] as? String {
                        standardErrorURL = URL(fileURLWithPath: (errPath as NSString).expandingTildeInPath)
                    }
                    if let workDir = dict["WorkingDirectory"] as? String {
                        let workURL = URL(fileURLWithPath: (workDir as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
                        workingDirectoryURL = workURL
                        if workURL.path != runnerDirURL.path {
                            validationIssues.append("LaunchAgent WorkingDirectory (\(workURL.path)) does not match runner directory (\(runnerDirURL.path)).")
                        }
                    }
                    if let args = dict["ProgramArguments"] as? [String] {
                        programArguments = args
                        if let executable = args.first {
                            let execURL = URL(fileURLWithPath: executable)
                            if !fileManager.fileExists(atPath: execURL.path) {
                                validationIssues.append("LaunchAgent executable is missing at \(executable).")
                            }
                        } else {
                            validationIssues.append("LaunchAgent ProgramArguments is empty.")
                        }
                    } else {
                        validationIssues.append("LaunchAgent ProgramArguments is missing.")
                    }
                    runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
                    if let keepAliveBool = dict["KeepAlive"] as? Bool {
                        keepAlive = keepAliveBool
                    } else if let keepAliveDict = dict["KeepAlive"] as? [String: Any] {
                        keepAlive = !keepAliveDict.isEmpty
                    }
                    throttleInterval = dict["ThrottleInterval"] as? Int
                    if plistLabel == nil || plistLabel?.isEmpty == true {
                        validationIssues.append("LaunchAgent plist is missing a valid Label.")
                    }
                } else {
                    validationIssues.append("LaunchAgent plist at \(plistURL.path) is malformed or unreadable.")
                }
            } else if isServiceFilePresent {
                validationIssues.append("LaunchAgent plist referenced by .service is missing at \(plistURL.path).")
            }
        }

        let resolvedServiceName = plistLabel
            ?? serviceFilePlistURL?.deletingPathExtension().lastPathComponent
            ?? svcScriptServiceName

        guard let serviceName = resolvedServiceName, !serviceName.isEmpty else {
            if isServiceFilePresent {
                return RunnerServiceConfig(
                    serviceName: "unknown",
                    plistURL: serviceFilePlistURL,
                    isServiceFilePresent: true,
                    isPlistPresent: isPlistPresent,
                    validationIssues: validationIssues.isEmpty ? ["Could not determine LaunchAgent service name."] : validationIssues
                )
            }
            return nil
        }

        return RunnerServiceConfig(
            serviceName: serviceName,
            plistURL: candidatePlistURL,
            isServiceFilePresent: isServiceFilePresent,
            isPlistPresent: isPlistPresent,
            standardOutURL: standardOutURL,
            standardErrorURL: standardErrorURL,
            workingDirectoryURL: workingDirectoryURL,
            programArguments: programArguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            throttleInterval: throttleInterval,
            validationIssues: validationIssues
        )
    }

    private func discoverDiagnosticLogs(in runnerDirURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let diagDirURL = runnerDirURL.appendingPathComponent("_diag", isDirectory: true)
        guard Self.isSubpath(diagDirURL.resolvingSymlinksInPath(), of: runnerDirURL),
              let files = try? fileManager.contentsOfDirectory(
                  at: diagDirURL,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return files
            .filter { url in
                let name = url.lastPathComponent
                guard (name.hasPrefix("Runner_") || name.hasPrefix("Worker_")) && name.hasSuffix(".log") else {
                    return false
                }
                return Self.isSafeRegularFile(url, inside: runnerDirURL)
            }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if dateA != dateB {
                    return dateA > dateB
                }
                return a.lastPathComponent > b.lastPathComponent
            }
    }

    public static func extractServiceNameFromSvcScript(_ content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SVC_NAME=") {
                var value = String(trimmed.dropFirst("SVC_NAME=".count))
                if value.contains("${SVC_NAME") {
                    continue
                }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let normalized = value.replacingOccurrences(of: " ", with: "_")
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    public static func isSubpath(_ childURL: URL, of parentURL: URL) -> Bool {
        let childPath = childURL.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parentURL.standardizedFileURL.resolvingSymlinksInPath().path
        if childPath == parentPath {
            return true
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    public static func isSafeRegularFile(_ fileURL: URL, inside boundaryURL: URL) -> Bool {
        let resolvedFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isSubpath(resolvedFile, of: boundaryURL) else {
            return false
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedFile.path, isDirectory: &isDir)
        return exists && !isDir.boolValue && FileManager.default.isReadableFile(atPath: resolvedFile.path)
    }
}
