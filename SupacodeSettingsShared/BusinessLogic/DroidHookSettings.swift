import Foundation

nonisolated enum DroidHookSettings {
  /// Canonical hook map for Factory Droid. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: DroidHooksPayload(),
      invalidConfiguration: DroidHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum DroidHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Factory Droid loads `~/.factory/hooks.json` and uses the Claude-compatible
// PascalCase event names:
// - UserPromptSubmit / PreToolUse fire `busy`
// - PostToolUse fires `idle`
// - Notification fires `awaitingInput` and forwards stdin as notification
// - Stop fires `idle` and forwards notification
// - SessionStart fires `sessionStart`
// - SessionEnd fires `sessionEnd` and `idle`
private nonisolated struct DroidHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"
  private static let timeout = AgentHookSettingsCommand.timeoutSeconds

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .droid)
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .droid)
  private static let awaitingInputAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: true, agent: .droid)
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .droid)
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .droid)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .droid)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .droid)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: Self.timeout)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: Self.timeout)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: Self.timeout)]),
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: Self.timeout)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.idle, timeout: Self.timeout)])
    ],
    "Notification": [
      .init(
        matcher: "",
        hooks: [.init(command: Self.awaitingInputAndNotify, timeout: Self.timeout)]
      )
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.idleAndNotify, timeout: Self.timeout)])
    ],
    "SessionEnd": [
      .init(matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: Self.timeout)])
    ],
  ]
}
