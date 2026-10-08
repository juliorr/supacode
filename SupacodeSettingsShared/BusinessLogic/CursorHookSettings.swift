import Foundation

nonisolated enum CursorHookSettings {
  /// Single canonical hook map for Cursor. See `ClaudeHookSettings` for the
  /// composite-command rationale (one Supacode-managed entry per slot →
  /// idempotent prune-and-replace).
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CursorHooksPayload(),
      invalidConfiguration: CursorHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum CursorHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Cursor hook entry (flat native format: command + matcher + timeout).

/// Cursor's native `hooks.json` entry is flat — no Claude-style `type`/group
/// wrapper — with `command`, an optional `matcher` (omitted entries match
/// every tool), and `timeout` in **seconds** (not Kiro's `timeout_ms`).
nonisolated struct CursorHookEntry: Encodable {
  let command: String
  let matcher: String?
  let timeout: Int

  init(command: String, matcher: String? = nil, timeout: Int) {
    if command.isEmpty {
      assertionFailure("Cursor hook command must not be empty.")
    }
    if timeout <= 0 {
      assertionFailure("Cursor hook timeout must be positive, got \(timeout).")
    }
    self.command = command
    self.matcher = matcher
    self.timeout = max(1, timeout)
  }

  private enum CodingKeys: String, CodingKey {
    case command, matcher, timeout
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(command, forKey: .command)
    if let matcher {
      try container.encode(matcher, forKey: .matcher)
    }
    try container.encode(timeout, forKey: .timeout)
  }
}

// MARK: - Hook payload.

// Cursor (the Agent CLI and the IDE share `~/.cursor/hooks.json`) uses camelCase
// event names with Claude-Code-compatible semantics:
// - `beforeSubmitPrompt` (Claude's `UserPromptSubmit`) fires `busy`
// - `preToolUse` fires `busy`
// - `postToolUse` fires `idle`
// - `preCompact` fires `compacting`; Cursor has no post-compact event, so the
//   badge clears at the next idle (a `postToolUse` or the turn's `stop`)
// - `stop` fires `idle` and forwards the hook payload as a notification
//   (Cursor's stop input carries no message field today, so the notify leg is
//   a graceful no-op and the CLI's native OSC 9 keeps covering turn-end pings)
// - `sessionStart` / `sessionEnd` fire `sessionStart` / `sessionEnd` (+ `idle`)
// Cursor has no `Notification` event and no ask-user tool, so it gets no
// input-needed badge; matchers are omitted so each entry runs on every tool.
private nonisolated struct CursorHooksPayload: Encodable {
  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .cursor)
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .cursor)
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .cursor)
  private static let compacting = AgentHookSettingsCommand.compositeCommand(
    events: [.compacting], forwardStdinAsNotification: false, agent: .cursor)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .cursor)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .cursor)

  private static let timeout = AgentHookSettingsCommand.timeoutSeconds

  let hooks: [String: [CursorHookEntry]] = [
    "sessionStart": [
      CursorHookEntry(command: Self.sessionStart, timeout: Self.timeout)
    ],
    "beforeSubmitPrompt": [
      CursorHookEntry(command: Self.busy, timeout: Self.timeout)
    ],
    "preToolUse": [
      CursorHookEntry(command: Self.busy, timeout: Self.timeout)
    ],
    "postToolUse": [
      CursorHookEntry(command: Self.idle, timeout: Self.timeout)
    ],
    "preCompact": [
      CursorHookEntry(command: Self.compacting, timeout: Self.timeout)
    ],
    "stop": [
      CursorHookEntry(command: Self.idleAndNotify, timeout: Self.timeout)
    ],
    "sessionEnd": [
      CursorHookEntry(command: Self.sessionEndAndIdle, timeout: Self.timeout)
    ],
  ]
}
