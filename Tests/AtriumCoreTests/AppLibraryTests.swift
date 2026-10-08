import Foundation
import Testing
@testable import AtriumCore

private func app(_ id: String) -> ManagedApp {
    ManagedApp(bundleIdentifier: id, displayName: id, lastKnownPath: "/Applications/\(id).app")
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("atrium-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("apps.json")
}

@Test func addDedupesByBundleID() {
    var lib = AppLibrary()
    #expect(lib.add(app("a")))
    #expect(!lib.add(app("a")))
    #expect(lib.apps.count == 1)
}

@Test func removeByBundleID() {
    var lib = AppLibrary(apps: [app("a"), app("b")])
    lib.remove(bundleIdentifier: "a")
    #expect(lib.apps.map(\.bundleIdentifier) == ["b"])
}

@Test func moveMatchesOnMoveSemantics() {
    var lib = AppLibrary(apps: [app("a"), app("b"), app("c"), app("d")])
    lib.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)      // a goes after c
    #expect(lib.apps.map(\.bundleIdentifier) == ["b", "c", "a", "d"])
    lib.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)      // d goes to the front
    #expect(lib.apps.map(\.bundleIdentifier) == ["d", "b", "c", "a"])
}

@Test func saveLoadRoundTrip() throws {
    let url = tempURL()
    var lib = AppLibrary(apps: [app("a"), app("b")])
    lib.update(bundleIdentifier: "b") { $0.snapWindow = false; $0.openAtLogin = true }
    try lib.save(to: url)
    let loaded = AppLibrary.load(from: url)
    #expect(loaded.library == lib)
    #expect(loaded.corruptBackup == nil)
}

@Test func missingFileLoadsEmpty() {
    let loaded = AppLibrary.load(from: tempURL())
    #expect(loaded.library.apps.isEmpty)
    #expect(loaded.corruptBackup == nil)
}

@Test func corruptFileIsRenamedAndLoadsEmpty() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    let loaded = AppLibrary.load(from: url)
    #expect(loaded.library.apps.isEmpty)
    let backup = try #require(loaded.corruptBackup)
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func oldJSONWithoutOptionalFieldsGetsDefaults() throws {
    let json = #"[{"bundleIdentifier":"x","displayName":"X","lastKnownPath":"/x"}]"#
    let apps = try JSONDecoder().decode([ManagedApp].self, from: Data(json.utf8))
    #expect(apps[0].snapWindow == true)
    #expect(apps[0].openAtLogin == false)
}
