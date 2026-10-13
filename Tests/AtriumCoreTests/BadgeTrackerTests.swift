import Testing
@testable import AtriumCore

private let m = "messenger"

/// Feeds a sequence of title readings 2 s apart; returns what was shown after each and how many sounds played.
private func run(_ readings: [BadgeText?], inView: Set<String> = []) -> (shown: [BadgeText?], sounds: Int) {
    var tracker = BadgeTracker()
    var shown: [String: BadgeText] = [:]
    var history: [BadgeText?] = []
    var sounds = 0
    _ = tracker.update(now: 0, readings: [m: nil], titleBased: [m], shown: shown, inView: inView)   // baseline
    for (i, r) in readings.enumerated() {
        let result = tracker.update(now: Double(i + 1) * 2, readings: [m: r], titleBased: [m], shown: shown, inView: inView)
        shown = result.badges
        history.append(shown[m])
        if result.newArrival { sounds += 1 }
    }
    return (history, sounds)
}

@Test func blinkingTitleShowsASteadyBadgeAndOneSound() {
    // The pattern seen in Messenger: the count disappears and comes back every couple of seconds.
    let r = run([.count(1), nil, .count(1), nil, .count(1), nil, .count(1)])
    #expect(r.shown.allSatisfy { $0 == .count(1) })
    #expect(r.sounds == 1)
}

@Test func badgeClearsAfterTheTitleStaysClean() {
    let r = run([.count(1), nil, nil, nil, nil, nil, nil])        // 12 s without a count
    #expect(r.shown.first == .count(1))
    #expect((r.shown.last ?? nil) == nil)
}

@Test func aHigherCountSoundsAgainButTheSameCountDoesNot() {
    let r = run([.count(1), .count(1), .count(2), nil, .count(2), .count(3)])
    #expect(r.sounds == 3)        // 1, then 2, then 3
}

@Test func afterBeingReadANewMessageSoundsAgain() {
    let r = run([.count(1), nil, nil, nil, nil, nil, nil, .count(1)])
    #expect(r.sounds == 2)
}

@Test func noSoundForTheAppYouAreLookingAt() {
    let r = run([.count(1), .count(2)], inView: [m])
    #expect(r.sounds == 0)
}

@Test func dockBadgesAreNotHeld() {
    var tracker = BadgeTracker()
    _ = tracker.update(now: 0, readings: ["slack": .dot], titleBased: [], shown: [:], inView: [])
    let r = tracker.update(now: 2, readings: ["slack": nil], titleBased: [], shown: ["slack": .dot], inView: [])
    #expect(r.badges["slack"] == nil)
}
