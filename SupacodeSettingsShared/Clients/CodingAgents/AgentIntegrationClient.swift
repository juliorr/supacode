import ComposableArchitecture
import Foundation

/// Per-agent unified install/uninstall surface. Wraps `AgentIntegration` so
/// reducers don't have to construct one per call. Tests stub this directly
/// instead of the underlying per-component clients.
public nonisolated struct AgentIntegrationClient: Sendable {
  /// Throws when the on-disk state can't be determined (see `AgentFileProbe`).
  /// Callers must not treat that as "not installed".
  public var state: @Sendable (AgentInstallTarget) async throws -> AgentIntegrationState
  public var install: @Sendable (AgentInstallTarget) async throws -> Void
  public var uninstall: @Sendable (AgentInstallTarget) async throws -> Void
  /// Synchronous existence probe for the target's config directory. Riding the
  /// client (rather than calling `FileManager` inline in a reducer effect)
  /// lets tests pin `configDirectoriesOnDisk` deterministically instead of
  /// depending on which agents happen to be installed on the machine.
  public var configDirectoryExists: @Sendable (AgentInstallTarget) -> Bool

  public init(
    state: @escaping @Sendable (AgentInstallTarget) async throws -> AgentIntegrationState,
    install: @escaping @Sendable (AgentInstallTarget) async throws -> Void,
    uninstall: @escaping @Sendable (AgentInstallTarget) async throws -> Void,
    configDirectoryExists: @escaping @Sendable (AgentInstallTarget) -> Bool
  ) {
    self.state = state
    self.install = install
    self.uninstall = uninstall
    self.configDirectoryExists = configDirectoryExists
  }
}

extension AgentIntegrationClient: DependencyKey {
  public static let liveValue = Self(
    state: { target in
      try AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).state()
    },
    install: { target in
      try await AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).install()
    },
    uninstall: { target in
      try AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).uninstall()
    },
    configDirectoryExists: { target in
      FileManager.default.fileExists(atPath: target.configDirectory().path(percentEncoded: false))
    }
  )

  public static let testValue = Self(
    state: { _ in .notInstalled },
    install: { _ in },
    uninstall: { _ in },
    configDirectoryExists: { _ in false }
  )
}

extension DependencyValues {
  public var agentIntegrationClient: AgentIntegrationClient {
    get { self[AgentIntegrationClient.self] }
    set { self[AgentIntegrationClient.self] = newValue }
  }
}
