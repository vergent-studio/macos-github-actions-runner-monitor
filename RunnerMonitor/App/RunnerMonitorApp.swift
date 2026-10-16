import SwiftUI

@main
struct RunnerMonitorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarIndicatorLabel(
                aggregateStatus: appState.aggregateStatus,
                runners: appState.runners
            )
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIndicatorLabel: View {
    let aggregateStatus: AggregateRunnerStatus
    let runners: [Runner]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: aggregateStatus.symbolName)
                .symbolRenderingMode(.hierarchical)
            if !badgeCountText.isEmpty {
                Text(badgeCountText)
                    .font(.caption2.monospacedDigit())
            }
        }
        .accessibilityLabel(aggregateStatus.title)
    }

    private var badgeCountText: String {
        guard !runners.isEmpty else { return "" }
        let busyCount = runners.filter { $0.status == .busy }.count
        if busyCount > 0 {
            return "\(busyCount)/\(runners.count)"
        }
        return "\(runners.count)"
    }
}
