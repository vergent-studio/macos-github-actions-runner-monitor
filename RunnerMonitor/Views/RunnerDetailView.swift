import AppKit
import SwiftUI

public struct RunnerDetailView: View {
    public let runner: Runner
    public let events: [RunnerEvent]
    public let logEntries: [RunnerLogEntry]
    public let onRefreshLogs: () -> Void
    public let onBack: () -> Void

    @State private var selectedTab: DetailTab = .overview

    public enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"

        public var id: String { rawValue }
    }

    public init(
        runner: Runner,
        events: [RunnerEvent],
        logEntries: [RunnerLogEntry],
        onRefreshLogs: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        self.runner = runner
        self.events = events
        self.logEntries = logEntries
        self.onRefreshLogs = onRefreshLogs
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(runner.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                StatusBadgeView(status: runner.status)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if selectedTab == .overview {
                overviewContent
            } else {
                LogViewer(
                    runner: runner,
                    entries: logEntries,
                    onRefresh: onRefreshLogs
                )
            }
        }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Status & Explanation
                sectionCard(title: "Status & Activity") {
                    detailRow(label: "State", value: runner.status.displayTitle)
                    detailRow(label: "Summary", value: runner.statusExplanation)

                    if let job = runner.currentJob {
                        detailRow(label: "Active Job", value: job.jobName)
                        if let started = job.startedAt {
                            detailRow(label: "Job Started", value: Self.dateTimeFormatter.string(from: started))
                        }
                    }

                    if let completed = runner.lastCompletedJob {
                        let resultText = completed.result.map { " (\($0))" } ?? ""
                        detailRow(label: "Last Completed Job", value: "\(completed.jobName)\(resultText)")
                    }

                    if let lastActivity = runner.lastActivityAt {
                        detailRow(label: "Last Observed Activity", value: Self.dateTimeFormatter.string(from: lastActivity))
                    }
                }

                // Error / Failure info if present
                if let failure = runner.lastFailureMessage {
                    sectionCard(title: "Last Observed Error / Issue") {
                        Text(failure)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        if let failDate = runner.lastFailureAt {
                            Text("Observed at \(Self.dateTimeFormatter.string(from: failDate))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Process & LaunchAgent Info
                sectionCard(title: "Service & Process") {
                    detailRow(
                        label: "LaunchAgent ID",
                        value: runner.serviceConfig?.serviceName ?? "Not configured"
                    )
                    detailRow(
                        label: "Service Installed",
                        value: (runner.serviceConfig?.isServiceFilePresent == true && runner.serviceConfig?.isPlistPresent == true) ? "Yes" : "No (.service missing)"
                    )
                    if let svc = runner.serviceConfig, svc.isPlistPresent {
                        detailRow(label: "RunAtLoad / KeepAlive", value: "\(svc.runAtLoad ? "Yes" : "No") / \(svc.keepAlive ? "Yes" : "No")")
                    }
                    detailRow(
                        label: "Service PID",
                        value: runner.servicePID.map(String.init) ?? "Not running"
                    )
                    if let listenerPID = runner.listenerPID {
                        detailRow(label: "Listener PID", value: String(listenerPID))
                    }
                    if let exitCode = runner.lastExitCode {
                        detailRow(label: "Last Exit Code", value: String(exitCode))
                    }
                    detailRow(label: "Observed Restarts", value: String(runner.restartCount))
                }

                // Installation & Registration Info
                sectionCard(title: "Runner Installation") {
                    detailRow(label: "Directory", value: runner.directoryURL.path)
                    if let repo = runner.registration?.gitHubUrl {
                        detailRow(label: "Repository / Org", value: repo)
                    }
                    if let agentId = runner.registration?.agentId {
                        detailRow(label: "Agent ID", value: "#\(agentId) (\(runner.registration?.poolName ?? "Default"))")
                    }
                    if let version = runner.runnerVersion {
                        detailRow(label: "Runner Version", value: version)
                    }

                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([runner.directoryURL])
                        } label: {
                            Label("Show Runner in Finder", systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            let diagURL = runner.diagDirectoryURL
                            if FileManager.default.fileExists(atPath: diagURL.path) {
                                NSWorkspace.shared.open(diagURL)
                            } else {
                                NSWorkspace.shared.open(runner.directoryURL)
                            }
                        } label: {
                            Label("Open _diag Logs", systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }

                // Recent Lifecycle Events for this runner
                if !events.isEmpty {
                    sectionCard(title: "Recent Lifecycle Events") {
                        ForEach(events.prefix(8)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.dateTimeFormatter.string(from: event.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.summary)
                                    .font(.caption)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 460)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 125, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
