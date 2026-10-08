import Foundation

private nonisolated let cursorInstallerLogger = SupaLogger("Settings")

/// File installer for Cursor's native hook format
/// (`{ version, hooks → event → [{ command, matcher?, timeout }] }`). Mirrors
/// `KiroHookSettingsFileInstaller`'s flat-entry prune-and-replace, plus two
/// Cursor-specific duties: guarantee the root `version` the schema requires
/// (a file we create fresh would otherwise be rejected), and never conjure the
/// file when uninstalling a never-installed integration.
nonisolated struct CursorHookSettingsFileInstaller {
  typealias Errors = JSONHookSettingsFile.Errors

  /// The only `hooks.json` schema version Cursor documents today.
  private static let configSchemaVersion = 1

  let fileManager: FileManager
  let errors: Errors
  let logWarning: @Sendable (String) -> Void

  init(
    fileManager: FileManager,
    errors: Errors,
    logWarning: @escaping @Sendable (String) -> Void = { cursorInstallerLogger.warning($0) }
  ) {
    self.fileManager = fileManager
    self.errors = errors
    self.logWarning = logWarning
  }

  private var file: JSONHookSettingsFile {
    JSONHookSettingsFile(fileManager: fileManager, errors: errors)
  }

  // MARK: - Check.

  /// Throws when the file can't be read or parsed: an unreadable file is not
  /// an uninstalled one.
  func installState(
    settingsURL: URL,
    hookEntriesByEvent: [String: [JSONValue]]
  ) throws -> ComponentInstallState {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      let expected = Self.commands(from: hookEntriesByEvent)
      guard !expected.isEmpty else { return .notInstalled }
      let actual = Self.installedSupacodeCommands(in: settingsObject)
      if actual.isEmpty { return .notInstalled }
      return actual == expected ? .installed : .outdated
    } catch {
      logWarning("Failed to inspect Cursor hook settings at \(settingsURL.path): \(error)")
      throw error
    }
  }

  private static func installedSupacodeCommands(
    in settingsObject: [String: JSONValue]
  ) -> Set<String> {
    guard let hooksObject = settingsObject["hooks"]?.objectValue else { return [] }
    var commands = Set<String>()
    for (_, value) in hooksObject {
      guard let entries = value.arrayValue else { continue }
      for entry in entries {
        guard let entryObject = entry.objectValue,
          let command = entryObject["command"]?.stringValue,
          AgentHookCommandOwnership.isSupacodeManagedCommand(command)
        else { continue }
        commands.insert(command)
      }
    }
    return commands
  }

  // MARK: - Install.

  /// `install = uninstall + append`: strip every Supacode-managed entry,
  /// then append the canonical entries 1:1. The root `version` is only ever
  /// filled in when absent: an existing value is the user's (or a future
  /// Cursor's) call, never ours to rewrite.
  func install(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let canonicalEntries = try hookEntriesByEvent()
    var settingsObject = try loadSettingsObject(at: settingsURL)
    let existing = try existingHooksObject(in: settingsObject)
    var pruned = try pruneAllSupacodeEntries(from: existing)
    for (event, entries) in canonicalEntries {
      let existingEntries = pruned[event]?.arrayValue ?? []
      pruned[event] = .array(existingEntries + entries)
    }
    settingsObject["hooks"] = .object(pruned)
    if settingsObject["version"] == nil {
      settingsObject["version"] = .int(Self.configSchemaVersion)
    }
    try writeSettings(settingsObject, to: settingsURL)
  }

  // MARK: - Uninstall.

  /// No-op while the file is absent, so uninstalling a never-installed
  /// integration leaves the filesystem untouched. Otherwise strip every
  /// Supacode-managed entry and drop an emptied `hooks` map; the surviving
  /// root keys (`version` included) keep the file valid, and user-authored
  /// entries survive untouched.
  func uninstall(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    _ = try hookEntriesByEvent()  // Eval for parity with `install` errors.
    guard try AgentFileProbe.data(at: settingsURL) != nil else { return }
    var settingsObject = try loadSettingsObject(at: settingsURL)
    let existing = try existingHooksObject(in: settingsObject)
    let pruned = try pruneAllSupacodeEntries(from: existing)
    if pruned.isEmpty {
      settingsObject.removeValue(forKey: "hooks")
    } else {
      settingsObject["hooks"] = .object(pruned)
    }
    try writeSettings(settingsObject, to: settingsURL)
  }

  // MARK: - Helpers.

  private static func commands(from hookEntriesByEvent: [String: [JSONValue]]) -> Set<String> {
    var commands = Set<String>()
    for (_, entries) in hookEntriesByEvent {
      for entry in entries {
        guard let entryObject = entry.objectValue,
          let command = entryObject["command"]?.stringValue
        else { continue }
        commands.insert(command)
      }
    }
    return commands
  }

  private static func isManaged(_ entry: JSONValue) -> Bool {
    guard let entryObject = entry.objectValue,
      let command = entryObject["command"]?.stringValue
    else { return false }
    return AgentHookCommandOwnership.isSupacodeManagedCommand(command)
  }

  /// Builds a fresh hooks map with every Supacode-managed entry stripped.
  /// Iterates the source dict (never mutates while iterating) so the prune
  /// can't silently skip an event.
  private func pruneAllSupacodeEntries(
    from hooksObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (event, value) in hooksObject {
      guard let entries = value.arrayValue else {
        throw errors.invalidEventHooks(event)
      }
      let filtered = entries.filter { !Self.isManaged($0) }
      if !filtered.isEmpty {
        result[event] = .array(filtered)
      }
    }
    return result
  }

  private func existingHooksObject(
    in settingsObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard let hooksValue = settingsObject["hooks"] else { return [:] }
    guard let hooksObject = hooksValue.objectValue else {
      throw errors.invalidHooksObject()
    }
    return hooksObject
  }

  private func loadSettingsObject(at url: URL) throws -> [String: JSONValue] {
    try file.load(at: url)
  }

  private func writeSettings(_ object: [String: JSONValue], to url: URL) throws {
    try file.write(object, to: url)
  }
}
