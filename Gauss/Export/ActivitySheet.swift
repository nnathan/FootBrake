import UIKit

/// Presents the system share sheet and reports where the file went.
/// (SwiftUI's `ShareLink` gives no completion callback.)
@MainActor
enum ActivitySheet {
    static func present(_ url: URL, completion: @escaping (UIActivity.ActivityType?, Bool) -> Void) {
        guard let presenter = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { type, completed, _, _ in completion(type, completed) }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 120,
                                        width: 1, height: 1)
        }
        presenter.present(controller, animated: true)
    }

    /// A past-tense description and SF Symbol for a completed share.
    static func describe(_ type: UIActivity.ActivityType?) -> (text: String, icon: String) {
        switch type {
        case .airDrop?: return ("Sent with AirDrop", "dot.radiowaves.left.and.right")
        case .mail?: return ("Sent with Mail", "envelope")
        case .message?: return ("Sent with Messages", "message")
        case .saveToCameraRoll?: return ("Saved to Photos (via share sheet)", "photo.on.rectangle")
        case .copyToPasteboard?: return ("Copied", "doc.on.doc")
        case let type? where type.rawValue.contains("SaveToFiles"): return ("Saved to Files", "folder")
        case let type?:
            if let app = appName(fromActivity: type.rawValue) {
                return ("Shared to \(app)", "square.and.arrow.up")
            }
            return ("Shared", "square.and.arrow.up")
        case nil:
            return ("Shared", "square.and.arrow.up")
        }
    }

    /// Best-effort app name from a share extension's activity type, e.g.
    /// `net.whatsapp.WhatsApp.ShareExtension` → `WhatsApp`.
    static func appName(fromActivity raw: String) -> String? {
        let known = ["com.apple.mobilenotes": "Notes", "com.apple.reminders": "Reminders",
                     "com.apple.freeform": "Freeform", "com.apple.iBooks": "Books"]
        if let match = known.first(where: { raw.hasPrefix($0.key) }) { return match.value }

        var parts = raw.split(separator: ".").map(String.init)
        let noise = ["share", "extension", "action", "post", "compose", "intents"]
        while let last = parts.last, noise.contains(where: { last.lowercased().contains($0) }) {
            parts.removeLast()
        }
        guard parts.count >= 2, let name = parts.last,
              name.count >= 2, !["com", "net", "org", "app", "ios"].contains(name.lowercased())
        else { return nil }
        return name
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
