import SwiftUI

public struct RunnerRow: View {
    public let runner: Runner
    public let onSelect: () -> Void

    public init(runner: Runner, onSelect: @escaping () -> Void) {
        self.runner = runner
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: runner.status.symbolName)
                        .foregroundStyle(statusColor(for: runner.status))
                        .imageScale(.medium)
                        .accessibilityHidden(true)

                    Text(runner.displayName)
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if runner.displayName != runner.directoryName {
                        Text("(\(runner.directoryName))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    StatusBadgeView(status: runner.status)
                }

                if runner.status == .busy, let job = runner.currentJob {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        HStack(spacing: 6) {
                            Image(systemName: "hammer.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text(job.jobName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let elapsed = job.elapsedDuration(at: context.date) {
                                Text("· Running for \(RunnerJobInfo.formatDuration(elapsed))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text(runner.statusExplanation)
                        .font(.caption)
                        .foregroundStyle(runner.status == .failed ? .red : .secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if let repo = runner.registration?.repositoryDisplayName {
                        Label(repo, systemImage: "folder.badge.gearshape")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let pid = runner.displayPID {
                        Text("PID \(pid)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if runner.restartCount > 0 {
                        Label("\(runner.restartCount) restart\(runner.restartCount == 1 ? "" : "s")", systemImage: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(runner.displayName), status \(runner.status.displayTitle). \(runner.statusExplanation)")
    }
}

public struct StatusBadgeView: View {
    public let status: RunnerStatusState

    public init(status: RunnerStatusState) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text(status.badgeText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(statusColor(for: status))
        .background(
            Capsule(style: .continuous)
                .fill(statusColor(for: status).opacity(0.14))
        )
    }
}

public func statusColor(for status: RunnerStatusState) -> Color {
    switch status {
    case .idle:
        return .green
    case .busy:
        return .blue
    case .starting, .restarting:
        return .orange
    case .stopped:
        return .secondary
    case .notInstalled, .notConfigured:
        return .orange
    case .failed:
        return .red
    case .unknown:
        return .purple
    }
}
