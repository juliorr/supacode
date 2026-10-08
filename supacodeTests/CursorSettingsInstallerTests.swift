import Foundation
import Testing

@testable import SupacodeSettingsShared

struct CursorSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-cursor-installer-\(UUID().uuidString)", isDirectory: true)
  }

  private func loadSettingsObject(at settingsURL: URL) throws -> [String: JSONValue] {
    let data = try Data(contentsOf: settingsURL)
    return try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
  }

  @Test func settingsURLResolvesToCursorHooks() {
    let homeURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(url.path(percentEncoded: false) == "/Users/test/.cursor/hooks.json")
  }

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installStateThrowsWhenFileIsUnreadableAsUTF8() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Invalid UTF-8 bytes:
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: settingsURL)

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: (any Error).self) { try installer.installState() }
  }

  @Test func installAllHooksWritesSupacodeManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))

    let rootObject = try loadSettingsObject(at: settingsURL)
    // Cursor's native schema requires a root `version`; a fresh install must
    // write one rather than a file Cursor rejects.
    #expect(rootObject["version"] == .int(1))
    let hooksObject = try #require(rootObject["hooks"]?.objectValue)

    #expect(hooksObject["sessionStart"] != nil)
    #expect(hooksObject["beforeSubmitPrompt"] != nil)
    #expect(hooksObject["preToolUse"] != nil)
    #expect(hooksObject["postToolUse"] != nil)
    #expect(hooksObject["preCompact"] != nil)
    #expect(hooksObject["stop"] != nil)
    #expect(hooksObject["sessionEnd"] != nil)

    // Native flat entry shape: command + timeout in seconds, no Claude-style
    // `type`/group wrapper and no matcher (the entry runs on every tool).
    let stopEntries = try #require(hooksObject["stop"]?.arrayValue)
    #expect(stopEntries.count == 1)
    let stopEntry = try #require(stopEntries.first?.objectValue)
    #expect(
      stopEntry["command"]?.stringValue?.contains(AgentHookSettingsCommand.ownershipMarker) == true)
    #expect(stopEntry["timeout"] == .int(AgentHookSettingsCommand.timeoutSeconds))
    #expect(stopEntry["matcher"] == nil)
    #expect(stopEntry["type"] == nil)

    #expect(try installer.installState() == .installed)
  }

  @Test func installStateReturnsOutdatedWhenManagedBodyDrifted() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Ownership marker present but `stop` carries a stale busy command:
    let staleCommand = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .cursor)
    let stale: JSONValue = .object([
      "version": .int(1),
      "hooks": .object([
        "stop": .array([
          .object([
            "command": .string(staleCommand),
            "timeout": 5,
          ])
        ])
      ]),
    ])
    try JSONEncoder().encode(stale).write(to: settingsURL)

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .outdated)
  }

  @Test func uninstallRemovesManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let rootObject = try loadSettingsObject(at: settingsURL)
    #expect(rootObject["hooks"] == nil)
    #expect(rootObject["version"] == .int(1))
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "version": 1,
        "hooks": {
          "postToolUse": [
            {
              "command": "prettier --write"
            }
          ]
        }
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .installed)
  }

  @Test func uninstallPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "version": 1,
        "hooks": {
          "postToolUse": [
            {
              "command": "prettier --write"
            }
          ]
        }
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(!text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installKeepsExistingVersionValue() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "version": 2,
        "hooks": {
          "stop": [
            {
              "command": "echo done"
            }
          ]
        }
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let rootObject = try loadSettingsObject(at: settingsURL)
    // An existing version is the user's (or a future Cursor's) call; the
    // install only fills it in when absent.
    #expect(rootObject["version"] == .int(2))
    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("echo done"))
    #expect(try installer.installState() == .installed)
  }

  @Test func uninstallDoesNotCreateTheFileWhenAbsent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CursorSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.uninstallAllHooks()

    let settingsURL = CursorSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(!fileManager.fileExists(atPath: settingsURL.path))
  }
}
