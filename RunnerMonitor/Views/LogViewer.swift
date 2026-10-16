import AppKit
import SwiftUI

public struct LogViewer: View {
    public let runner: Runner
    public let entries: [RunnerLogEntry]
    public let onRefresh: () -> Void

    @State private var searchText: String = ""
    @State private var filterMode: LogFilterMode = .all
    @State private var selectedSource: LogSourceFilter = .all
    @State private var copyFeedback: Bool = false

    public enum LogFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case warningsAndErrors = "Warn / Err"
        case errorsOnly = "Errors"

        public var id: String { rawValue }
    }

    public enum LogSourceFilter: String, CaseIterable, Identifiable {
        case all = "All Sources"
        case runnerDiag = "Runner _diag"
        case workerDiag = "Worker _diag"
        case serviceOutput = "stdout/stderr"

        public var id: String { rawValue }
    }

    public init(
        runner: Runner,
        entries: [RunnerLogEntry],
        onRefresh: @escaping () -> Void
    ) {
        self.runner = runner
        self.entries = entries
        self.onRefresh = onRefresh
    }

    private var filteredEntries: [RunnerLogEntry] {
        entries.filter { entry in
            switch filterMode {
            case .all:
                break
            case .warningsAndErrors:
                guard entry.level == .warning || entry.level == .error else { return false }
            case .errorsOnly:
                guard entry.level == .error else { return false }
            }

            switch selectedSource {
            case .all:
                break
            case .runnerDiag:
                guard entry.sourceKind == .diagnosticRunner else { return false }
            case .workerDiag:
                guard entry.sourceKind == .diagnosticWorker else { return false }
            case .serviceOutput:
                guard entry.sourceKind == .standardOut || entry.sourceKind == .standardError else { return false }
            }

            if !searchText.isEmpty {
                let matchesMessage = entry.message.localizedCaseInsensitiveContains(searchText)
                let matchesComponent = entry.component?.localizedCaseInsensitiveContains(searchText) ?? false
                let matchesSource = entry.sourceName.localizedCaseInsensitiveContains(searchText)
                return matchesMessage || matchesComponent || matchesSource
            }
            return true
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Controls
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search logs…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                HStack(spacing: 6) {
                    Picker("Level", selection: $filterMode) {
                        ForEach(LogFilterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)

                    Picker("Source", selection: $selectedSource) {
                        ForEach(LogSourceFilter.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 115)
                }
            }
            .padding(.horizontal, 14)

            // Bounded Log List
            if filteredEntries.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching log entries")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Logs are read incrementally from _diag/ and service stdout/stderr.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            logRow(for: entry)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .frame(height: 330)
            }

            Divider()

            // Footer Actions
            HStack(spacing: 8) {
                Button {
                    copyFilteredLogsToPasteboard()
                } label: {
                    Label(copyFeedback ? "Copied!" : "Copy Logs", systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(filteredEntries.isEmpty)

                Button {
                    openLogDirectoryInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: onRefresh) {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func logRow(for entry: RunnerLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                levelBadge(for: entry.level)

                if let ts = entry.rawTimestamp {
                    Text(ts)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let comp = entry.component, !comp.isEmpty {
                    Text(comp)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.sourceName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor(for: entry.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor(for: entry.level))
        )
    }

    @ViewBuilder
    private func levelBadge(for level: LogLevel) -> some View {
        HStack(spacing: 2) {
            if level == .error {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 8))
            } else if level == .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
            }
            Text(level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(badgeColor(for: level))
    }

    private func badgeColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        case .other: return .secondary
        }
    }

    private func textColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info, .other: return .primary
        }
    }

    private func backgroundColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return Color.red.opacity(0.10)
        case .warning: return Color.orange.opacity(0.10)
        case .info, .other: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func copyFilteredLogsToPasteboard() {
        let formatted = filteredEntries.map { entry in
            let ts = entry.rawTimestamp ?? "-"
            let comp = entry.component ?? entry.sourceName
            return "[\(ts) \(entry.level.rawValue) \(comp)] \(entry.message)"
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatted, forType: .string)
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copyFeedback = false
        }
    }

    private func openLogDirectoryInFinder() {
        if selectedSource == .serviceOutput,
           let stdoutURL = runner.serviceConfig?.standardOutURL {
            let logDir = stdoutURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: logDir.path) {
                NSWorkspace.shared.open(logDir)
                return
            }
        }
        let diagURL = runner.diagDirectoryURL
        if FileManager.default.fileExists(atPath: diagURL.path) {
            NSWorkspace.shared.open(diagURL)
        } else {
            NSWorkspace.shared.open(runner.directoryURL)
        }
    }
}
