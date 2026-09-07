import Foundation

/// Top-level installer for Factory Droid hooks. Owns `~/.factory/hooks.json`
/// and merges into it with the prune-and-replace installer, so user-authored hooks
/// in that file survive.
nonisolated struct DroidSettingsInstaller {
  static let hookFileName = "hooks.json"

  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".factory", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map.
  func installState() throws -> ComponentInstallState {
    let groups: [String: [JSONValue]]
    do {
      groups = try DroidHookSettings.hooksByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error)
      return .notInstalled
    }
    return try fileInstaller.installState(
      settingsURL: settingsURL,
      hookGroupsByEvent: groups
    )
  }

  func installAllHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try DroidHookSettings.hooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try DroidHookSettings.hooksByEvent()
    )
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Factory Droid hook configuration is invalid: \(error)")
    #endif
  }

  private var settingsURL: URL {
    configDirectoryURL.appending(path: Self.hookFileName, directoryHint: .notDirectory)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".factory", directoryHint: .isDirectory)
      .appending(path: hookFileName, directoryHint: .notDirectory)
  }

  private var fileInstaller: AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { DroidSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { DroidSettingsInstallerError.invalidHooksObject },
        invalidJSON: { DroidSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { DroidSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum DroidSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Factory Droid hooks use an unsupported shape for \(event)."
    case .invalidHooksObject:
      "Factory Droid hooks use an unsupported shape."
    case .invalidJSON(let detail):
      "Factory Droid hooks must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Factory Droid hooks must be a JSON object before Supacode can install hooks."
    }
  }
}
