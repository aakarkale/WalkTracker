import UIKit

/// Physical feedback for the two moments that earn it: a block finished, and a
/// milestone crossed.
///
/// Deliberately sparse. Haptics that fire constantly stop meaning anything, and
/// they can be turned off entirely in Settings.
@MainActor
final class Haptics {

    var isEnabled = true

    private let notification = UINotificationFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    /// Warms up the Taptic Engine so the first tap of a walk is not late.
    func prepare() {
        guard isEnabled else { return }
        notification.prepare()
        impact.prepare()
    }

    func blockCompleted() {
        guard isEnabled else { return }
        impact.impactOccurred()
        impact.prepare()
    }

    func milestoneEarned() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }
}
