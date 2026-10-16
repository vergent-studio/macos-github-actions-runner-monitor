import Foundation
import UserNotifications

/// Dispatches local macOS notifications for runner lifecycle transitions without including sensitive log content.
public final class NotificationManager: Sendable {
    public static let shared = NotificationManager()

    public init() {}

    public func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func postNotification(
        for event: RunnerEvent,
        notifyOnFailures: Bool,
        notifyOnRestarts: Bool,
        notifyOnJobs: Bool
    ) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let title: String
        let body: String

        switch event.kind {
        case .serviceFailed:
            guard notifyOnFailures else { return }
            title = "Runner Service Failed"
            body = "\(event.runnerName) reported a service or startup failure."
        case .serviceRestarted:
            guard notifyOnRestarts else { return }
            title = "Runner Service Restarted"
            body = "\(event.runnerName) is restarting."
        case .jobStarted:
            guard notifyOnJobs else { return }
            title = "Job Started"
            body = "\(event.runnerName): \(event.summary)"
        case .jobCompleted:
            guard notifyOnJobs else { return }
            title = "Job Completed"
            body = "\(event.runnerName): \(event.summary)"
        case .serviceStarted, .serviceStopped, .runnerDiscovered, .runnerRemoved:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
