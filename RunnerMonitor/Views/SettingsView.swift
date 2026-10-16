import SwiftUI
import AppKit

/// Settings view embedded inside the menu bar window.
public struct SettingsView: View {
    @Bindable var appState: AppState
    public let onBack: () -> Void
    @State private var showConfirmSupervisionSetup: Bool = false

    public init(appState: AppState, onBack: @escaping () -> Void) {
        self.appState = appState
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    discoverySection
                    supervisionSetupSection
                    pollingSection
                    startupSection
                    notificationsSection
                    diagnosticsSection
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
        }
        .onAppear {
            appState.refreshSetupPlan()
        }
        .alert("Configure LaunchAgent Supervision?", isPresented: $showConfirmSupervisionSetup) {
            Button("Cancel", role: .cancel) {}
            Button("Apply & Start Services") {
                appState.applyServiceSupervisionSetup(startServices: true)
            }
        } message: {
            Text("This will back up existing LaunchAgent files, configure RunAtLoad, KeepAlive, and ThrottleInterval (30s) in ~/Library/LaunchAgents, and load the runner services.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var discoverySection: some View {
        settingsCard(title: "Runner Discovery") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Root Directory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("~/actions-runners", text: $appState.discoveryRootPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button("Choose…") {
                        chooseRunnerRootFolder()
                    }
                    .controlSize(.small)
                }

                Text("Runner Monitor scans child directories matching runner-* in read-only mode.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var supervisionSetupSection: some View {
        settingsCard(title: "Service Supervision Setup (LaunchAgent)") {
            VStack(alignment: .leading, spacing: 8) {
                if appState.setupPlanItems.isEmpty {
                    Text("No runner directories discovered for service supervision.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.setupPlanItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.runnerName)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text(item.action.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(item.action == .none ? .green : .orange)
                            }
                            Text(item.explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                    }

                    HStack(spacing: 8) {
                        Button("Inspect Plan") {
                            appState.refreshSetupPlan()
                        }
                        .controlSize(.small)

                        Button("Configure & Start LaunchAgents…") {
                            showConfirmSupervisionSetup = true
                        }
                        .controlSize(.small)
                        .disabled(appState.setupPlanItems.allSatisfy { $0.action == .skipNotConfigured })
                    }
                }

                if let statusMsg = appState.setupStatusMessage {
                    Text(statusMsg)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pollingSection: some View {
        settingsCard(title: "Monitoring & Logs") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Refresh interval")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $appState.refreshIntervalSeconds) {
                        Text("2 seconds").tag(2.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Displayed log lines")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $appState.maxDisplayedLogLines) {
                        Text("150 lines").tag(150)
                        Text("300 lines").tag(300)
                        Text("500 lines").tag(500)
                        Text("1000 lines").tag(1000)
                    }
                    .frame(width: 120)
                }
            }
        }
    }

    private var startupSection: some View {
        settingsCard(title: "Startup") {
            Toggle("Launch Runner Monitor at login", isOn: $appState.launchAtLogin)
                .font(.system(size: 12))
        }
    }

    private var notificationsSection: some View {
        settingsCard(title: "Notifications") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Runner failure", isOn: $appState.notifyOnFailures)
                    .font(.system(size: 12))
                Toggle("Automatic recovery / restart", isOn: $appState.notifyOnRestarts)
                    .font(.system(size: 12))
                Toggle("Job start & completion", isOn: $appState.notifyOnJobs)
                    .font(.system(size: 12))
            }
        }
    }

    private var diagnosticsSection: some View {
        settingsCard(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Discovered runners")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(appState.runners.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                if let duration = appState.lastRefreshDurationMs {
                    HStack {
                        Text("Last refresh duration")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f ms", duration))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                HStack {
                    Text("Bundle ID")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("studio.vergent.runnermonitor")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func chooseRunnerRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Runner Root"
        if panel.runModal() == .OK, let url = panel.url {
            appState.discoveryRootPath = url.path
        }
    }
}
