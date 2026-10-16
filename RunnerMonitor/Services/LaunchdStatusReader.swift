import Darwin
import Foundation

/// Snapshot of a LaunchAgent's runtime state as reported by `launchd`.
public struct LaunchdServiceSnapshot: Sendable, Equatable {
    public let serviceName: String
    public let isLoaded: Bool
    public let pid: Int32?
    public let lastExitStatus: Int32?
    public let runsCount: Int?
    public let stateDescription: String?
    public let querySucceeded: Bool
    public let errorMessage: String?

    public init(
        serviceName: String,
        isLoaded: Bool,
        pid: Int32? = nil,
        lastExitStatus: Int32? = nil,
        runsCount: Int? = nil,
        stateDescription: String? = nil,
        querySucceeded: Bool = true,
        errorMessage: String? = nil
    ) {
        self.serviceName = serviceName
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.runsCount = runsCount
        self.stateDescription = stateDescription
        self.querySucceeded = querySucceeded
        self.errorMessage = errorMessage
    }

    public var isRunning: Bool {
        if let pid, pid > 0 {
            return true
        }
        return stateDescription == "running"
    }
}

public protocol LaunchdStatusReading: Sendable {
    func readStatus(for serviceName: String) -> LaunchdServiceSnapshot
}

/// Reads per-user LaunchAgent state using `/bin/launchctl` with fixed arguments (no shell execution).
public struct LaunchdStatusReader: LaunchdStatusReading, Sendable {
    public let userID: uid_t

    public init(userID: uid_t = getuid()) {
        self.userID = userID
    }

    public func readStatus(for serviceName: String) -> LaunchdServiceSnapshot {
        let domainTarget = "gui/\(userID)/\(serviceName)"
        let printResult = Self.runLaunchctl(arguments: ["print", domainTarget])

        if printResult.TerminationStatus == 0 {
            return Self.parseLaunchctlPrintOutput(printResult.stdout, serviceName: serviceName)
        }

        // Fallback to `launchctl list <serviceName>`
        let listResult = Self.runLaunchctl(arguments: ["list", serviceName])
        if listResult.TerminationStatus == 0 {
            return Self.parseLaunchctlListDetailOutput(listResult.stdout, serviceName: serviceName)
        }

        // Service is not loaded in launchd (normal when stopped/unloaded)
        return LaunchdServiceSnapshot(
            serviceName: serviceName,
            isLoaded: false,
            pid: nil,
            lastExitStatus: nil,
            runsCount: nil,
            stateDescription: "not loaded",
            querySucceeded: true,
            errorMessage: nil
        )
    }

    // MARK: - Parsers (exposed internal/public for unit tests)

    public static func parseLaunchctlPrintOutput(_ output: String, serviceName: String) -> LaunchdServiceSnapshot {
        var pid: Int32?
        var lastExitStatus: Int32?
        var runsCount: Int?
        var stateDescription: String?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("pid = ") {
                let val = line.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces)
                if let parsed = Int32(val), parsed > 0 {
                    pid = parsed
                }
            } else if line.hasPrefix("state = ") {
                stateDescription = String(line.dropFirst("state = ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("runs = ") {
                let val = line.dropFirst("runs = ".count).trimmingCharacters(in: .whitespaces)
                runsCount = Int(val)
            } else if line.hasPrefix("last exit code = ") {
                let val = line.dropFirst("last exit code = ".count).trimmingCharacters(in: .whitespaces)
                if let parsed = Int32(val) {
                    lastExitStatus = parsed
                }
            }
        }

        return LaunchdServiceSnapshot(
            serviceName: serviceName,
            isLoaded: true,
            pid: pid,
            lastExitStatus: lastExitStatus,
            runsCount: runsCount,
            stateDescription: stateDescription,
            querySucceeded: true
        )
    }

    public static func parseLaunchctlListDetailOutput(_ output: String, serviceName: String) -> LaunchdServiceSnapshot {
        var pid: Int32?
        var lastExitStatus: Int32?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\"PID\" = ") {
                let val = line.dropFirst("\"PID\" = ".count).trimmingCharacters(in: CharacterSet(charactersIn: "; "))
                if let parsed = Int32(val), parsed > 0 {
                    pid = parsed
                }
            } else if line.hasPrefix("\"LastExitStatus\" = ") {
                let val = line.dropFirst("\"LastExitStatus\" = ".count).trimmingCharacters(in: CharacterSet(charactersIn: "; "))
                if let parsed = Int32(val) {
                    // launchctl list LastExitStatus is often waitpid status (exitCode << 8) or raw status
                    lastExitStatus = parsed > 255 ? (parsed >> 8) : parsed
                }
            }
        }

        return LaunchdServiceSnapshot(
            serviceName: serviceName,
            isLoaded: true,
            pid: pid,
            lastExitStatus: lastExitStatus,
            runsCount: nil,
            stateDescription: pid != nil ? "running" : "waiting",
            querySucceeded: true
        )
    }

    // MARK: - Process Execution

    private struct CommandOutput {
        let TerminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    private static func runLaunchctl(arguments: [String]) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandOutput(
                TerminationStatus: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandOutput(TerminationStatus: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
