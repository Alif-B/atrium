import SwiftUI

/// Named animations (docs/PLAN.md §7.8). `var` rather than `let` keeps Swift 6 concurrency checks quiet.
enum Motion {
    static var lensSlide: Animation { .snappy(duration: 0.32) }
    static var lensLift: Animation { .bouncy(duration: 0.4, extraBounce: -0.1) }
    static var hoverIn: Animation { .easeOut(duration: 0.12) }
    static var hoverOut: Animation { .easeIn(duration: 0.10) }
    static var label: Animation { .smooth(duration: 0.18) }
    static var press: Animation { .snappy(duration: 0.18) }
    static var badgeIn: Animation { .bouncy(duration: 0.35) }
    static var badgeCount: Animation { .snappy(duration: 0.25) }
    static var badgeOut: Animation { .smooth(duration: 0.2) }
    static var fade: Animation { .easeOut(duration: 0.2) }
    static var page: Animation { .smooth(duration: 0.35) }

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}
