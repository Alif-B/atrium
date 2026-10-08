import CoreGraphics
import Observation

enum HoverSlot: Hashable {
    case item(Int)
    case plus
    case gear
}

struct HoverTarget: Equatable {
    var slot: HoverSlot
    var title: String
    /// Vertical centre of the hovered control, measured from the top of the panel strip.
    var centerYInPanel: CGFloat
}

@MainActor @Observable
final class HoverState {
    var target: HoverTarget? {
        didSet { if target != oldValue { onTargetChange?(target) } }
    }
    @ObservationIgnored var onTargetChange: (@MainActor (HoverTarget?) -> Void)?
}
