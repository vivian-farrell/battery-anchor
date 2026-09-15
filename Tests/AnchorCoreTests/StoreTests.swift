import Foundation
import Testing
@testable import AnchorCore

private func temporaryStore() throws -> AnchorStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("battery-anchor-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("settings"), withIntermediateDirectories: true)
    return AnchorStore(directory: dir)
}

@Test func updateConfigStartsFromDefaultsWhenMissing() throws {
    let store = try temporaryStore()
    let saved = try store.updateConfig { $0.enabled = true }
    #expect(saved.enabled)
    #expect(saved.maxCharge == 80 && saved.rechargeBuffer == 5)
    #expect(try store.readConfig() == saved)
}

@Test func updateConfigPreservesOtherFields() throws {
    let store = try temporaryStore()
    try store.updateConfig {
        $0.maxCharge = 70
        $0.rechargeBuffer = 8
    }
    let saved = try store.updateConfig { $0.enabled = true }
    #expect(saved.enabled && saved.maxCharge == 70 && saved.rechargeBuffer == 8)
}

@Test func updateConfigRefusesToOverwriteInvalidConfig() throws {
    let store = try temporaryStore()
    let broken = Data(#"{"enabled":true,"maxCharge":70,"#.utf8)
    try broken.write(to: store.configURL)

    #expect(throws: AnchorStoreError.self) {
        try store.updateConfig { $0.enabled = false }
    }
    #expect(try Data(contentsOf: store.configURL) == broken)
}

@Test func atomicWriteReplacesSymlinkInsteadOfFollowingIt() throws {
    let store = try temporaryStore()
    let victim = store.directory.appendingPathComponent("victim")
    try Data("original".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: store.statusURL, withDestinationURL: victim)

    try AnchorStore.writeAtomically(Data("new".utf8), to: store.statusURL, permissions: 0o644)

    #expect(try String(contentsOf: victim, encoding: .utf8) == "original")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.statusURL.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
}

@Test func readRegularFileRejectsSymlinksAndReportsMissing() throws {
    let store = try temporaryStore()
    #expect(try AnchorStore.readRegularFile(store.configURL) == nil)

    let target = store.directory.appendingPathComponent("secret")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: store.configURL, withDestinationURL: target)
    #expect(throws: AnchorStoreError.self) {
        try AnchorStore.readRegularFile(store.configURL)
    }
}

@Test func stoppedDaemonIsNotAlive() {
    var status = makeStatus(config: AnchorConfig(), phase: nil)
    status.daemonPID = getpid()
    status.stopped = false
    #expect(AnchorStore.isDaemonAlive(status))
    status.stopped = true
    #expect(!AnchorStore.isDaemonAlive(status))
}
