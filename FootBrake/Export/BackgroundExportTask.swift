import BackgroundTasks
import Foundation

/// iOS 26+: asks iOS to keep a user-started export running if the user leaves
/// FootBrake. The system shows its own progress UI (Dynamic Island / Lock
/// Screen) and may still end the task, in which case `onExpire` runs.
@available(iOS 26, *)
@MainActor
final class BackgroundExportTask {
    private static let prefix = "net.lastninja.footbrake.export"
    private static let progressUnits: Int64 = 1000

    private var task: BGContinuedProcessingTask?
    private var progress = 0.0
    private var finished: Bool?

    /// Returns nil if iOS can't run the task right now; the export then
    /// carries on in the foreground only.
    init?(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        let identifier = "\(Self.prefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.adopt(task, onExpire: onExpire)
            }
        }
        guard registered else { return nil }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Start now or not at all: a queued export that runs later would be confusing.
        request.strategy = .fail
        // Rotating and scaling run on the GPU; not every device allows that in the background.
        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
        }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return nil
        }
    }

    /// Whether the device lets the export keep using the GPU in the background.
    static var supportsBackgroundGPU: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    func update(progress fraction: Double) {
        guard fraction.isFinite else { return }   // Int64(.nan) would crash
        progress = min(max(fraction, 0), 1)
        task?.progress.completedUnitCount = Int64(progress * Double(Self.progressUnits))
    }

    func finish(success: Bool) {
        finished = success
        task?.setTaskCompleted(success: success)
        task = nil
    }

    private func adopt(_ task: BGContinuedProcessingTask, onExpire: @escaping @MainActor () -> Void) {
        // The export may already have ended before iOS launched the task.
        if let finished {
            task.setTaskCompleted(success: finished)
            return
        }
        self.task = task
        task.progress.totalUnitCount = Self.progressUnits
        update(progress: progress)
        task.expirationHandler = {
            Task { @MainActor in onExpire() }
        }
    }
}
