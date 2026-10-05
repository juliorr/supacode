import Foundation
import Testing

@testable import SupacodeSettingsShared

struct DroidSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-droid-installer-\(UUID().uuidString)", isDirectory: true)
  }

  private func loadSettingsObject(at settingsURL: URL) throws -> [String: JSONValue] {
    let data = try Data(contentsOf: settingsURL)
    return try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
  }

  @Test func settingsURLResolvesToFactoryHooks() {
    let homeURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let url = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(url.path(percentEncoded: false) == "/Users/test/.factory/hooks.json")
  }

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installStateThrowsWhenFileIsUnreadableAsUTF8() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Invalid UTF-8 bytes:
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: settingsURL)

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: (any Error).self) { try installer.installState() }
  }

  @Test func installAllHooksWritesSupacodeManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let hooksObject = try #require(root.objectValue)

    #expect(root.objectValue?["hooks"] == nil)
    #expect(hooksObject["SessionStart"] != nil)
    #expect(hooksObject["UserPromptSubmit"] != nil)
    #expect(hooksObject["PreToolUse"] != nil)
    #expect(hooksObject["PostToolUse"] != nil)
    #expect(hooksObject["Notification"] != nil)
    #expect(hooksObject["Stop"] != nil)
    #expect(hooksObject["SessionEnd"] != nil)

    #expect(try installer.installState() == .installed)
  }

  @Test func installStateReturnsOutdatedWhenManagedBodyDrifted() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Ownership marker present but SessionStart carries a stale busy command:
    let staleCommand = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .droid)
    let stale: JSONValue = .object([
      "SessionStart": .array([
        .object([
          "hooks": .array([
            .object([
              "type": "command",
              "command": .string(staleCommand),
              "timeout": 5,
            ])
          ])
        ])
      ])
    ])
    try JSONEncoder().encode(stale).write(to: settingsURL)

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .outdated)
  }

  @Test func uninstallRemovesManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let hooksObject = root.objectValue ?? [:]
    #expect(hooksObject.isEmpty)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "PostToolUse": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "prettier --write"
              }
            ]
          }
        ]
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .installed)
  }

  @Test func uninstallPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "PostToolUse": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "prettier --write"
              }
            ]
          }
        ]
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(!text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installMigratesLegacyNestedHooksWrapper() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DroidSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let managedCommand = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: false, agent: .droid)
    let legacy: JSONValue = .object([
      "hooks": .object([
        "PostToolUse": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": "prettier --write",
              ]),
              .object([
                "type": "command",
                "command": .string(managedCommand),
              ]),
            ])
          ])
        ])
      ])
    ])
    try JSONEncoder().encode(legacy).write(to: settingsURL)

    let installer = DroidSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .outdated)

    try installer.installAllHooks()

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["hooks"] == nil)

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .installed)
  }
}
