import Foundation

/// Top-level installer for Cursor hooks. Owns `~/.cursor/hooks.json` — shared
/// by the IDE and the Agent CLI — and merges into it with the flat
/// prune-and-replace installer, so user-authored hooks in that file survive.
nonisolated struct CursorSettingsInstaller {
  static let hookFileName = "hooks.json"

  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".cursor", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map.
  func installState() throws -> ComponentInstallState {
    let entries: [String: [JSONValue]]
    do {
      entries = try CursorHookSettings.hooksByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error)
      return .notInstalled
    }
    return try fileInstaller.installState(
      settingsURL: settingsURL,
      hookEntriesByEvent: entries
    )
  }

  func installAllHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookEntriesByEvent: try CursorHookSettings.hooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookEntriesByEvent: try CursorHookSettings.hooksByEvent()
    )
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Cursor hook configuration is invalid: \(error)")
    #endif
  }

  private var settingsURL: URL {
    configDirectoryURL.appending(path: Self.hookFileName, directoryHint: .notDirectory)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".cursor", directoryHint: .isDirectory)
      .appending(path: hookFileName, directoryHint: .notDirectory)
  }

  private var fileInstaller: CursorHookSettingsFileInstaller {
    CursorHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { CursorSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { CursorSettingsInstallerError.invalidHooksObject },
        invalidJSON: { CursorSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { CursorSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum CursorSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Cursor hooks use an unsupported shape for \(event)."
    case .invalidHooksObject:
      "Cursor hooks use an unsupported shape."
    case .invalidJSON(let detail):
      "Cursor hooks must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Cursor hooks must be a JSON object before Supacode can install hooks."
    }
  }
}
