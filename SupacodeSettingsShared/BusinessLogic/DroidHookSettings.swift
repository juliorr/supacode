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
// - PreToolUse on AskUser / ExitSpecMode fires `awaitingInput`
// - Notification fires `awaitingInput` and forwards stdin as notification
// - PreCompact fires `compacting`; the post-compact SessionStart (source
//   `compact`) ends it, same lifecycle as Claude
// - Stop fires `idle` and forwards notification
// - SessionStart fires `sessionStart`
// - SessionEnd fires `sessionEnd` and `idle`
private nonisolated struct DroidHooksPayload: Encodable {
  /// Droid's own tool names (matchers run against them, not Claude's):
  /// `AskUser` is the interactive questionnaire tool and `ExitSpecMode`
  /// proposes a spec for approval. Claude's `AskUserQuestion|ExitPlanMode`
  /// never matches here.
  static let awaitingInputToolMatcher = "AskUser|ExitSpecMode"
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
  private static let compacting = AgentHookSettingsCommand.compositeCommand(
    events: [.compacting], forwardStdinAsNotification: false, agent: .droid)
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
    "PreCompact": [
      .init(hooks: [.init(command: Self.compacting, timeout: Self.timeout)])
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
