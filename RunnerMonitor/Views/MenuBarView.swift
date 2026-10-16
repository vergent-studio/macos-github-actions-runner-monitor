import AppKit
import SwiftUI

public struct MenuBarView: View {
    @Bindable var appState: AppState
    @State private var showingSettings: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Group {
            if showingSettings {
                SettingsView(
                    appState: appState,
                    onBack: { showingSettings = false }
                )
            } else if let selectedRunner = appState.selectedRunner {
                RunnerDetailView(
                    runner: selectedRunner,
                    events: appState.recentEvents.filter { $0.runnerId == selectedRunner.id },
                    logEntries: appState.selectedRunnerLogs,
                    onRefreshLogs: { appState.reloadLogsForSelectedRunner() },
                    onBack: { appState.selectRunner(nil) }
                )
            } else {
                dashboardView
            }
        }
        .frame(width: 420)
    }

    private var dashboardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Runner Monitor")
                        .font(.headline)
                    Text(appState.summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appState.triggerImmediateRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(appState.isRefreshing ? 360 : 0))
                }
                .buttonStyle(.borderless)
                .help("Refresh runner status now")
                .accessibilityLabel("Refresh runner status")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Runners Section
                    if appState.runners.isEmpty {
                        emptyStateView
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.runners) { runner in
                                RunnerRow(runner: runner) {
                                    appState.selectRunner(runner)
                                }
                            }
                        }
                    }

                    // Recent Activity Section
                    Divider()
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if appState.recentEvents.isEmpty {
                            Text("No lifecycle transitions observed during this session yet.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(appState.recentEvents.prefix(6)) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(Self.timeFormatter.string(from: event.timestamp))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Image(systemName: event.kind.symbolName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(event.runnerName)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)

                                    Text(event.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 440)

            Divider()

            // Footer
            HStack {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                if let refreshed = appState.lastRefreshedAt {
                    Text("Updated \(Self.timeFormatter.string(from: refreshed))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No runners discovered", systemImage: "Direct")
                .symbolVariant(.slash)
                .font(.subheadline.weight(.medium))
            Text("Checked discovery root: \(appState.discoveryRootPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Place registered official GitHub runner directories matching 'runner-*' inside the configured root.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
