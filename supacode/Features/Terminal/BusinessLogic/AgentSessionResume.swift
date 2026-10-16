import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// What a restored tab relaunches once its surface respawns: the AI CLI that
/// was running and, when the agent reported one, the session to resume into.
/// Live-only layout state: the persistence path always strips it, so it can
/// never outlive the process that computed it.
nonisolated struct ResumeIntent: Equatable, Codable, Sendable {
  let agent: SkillAgent
  let sessionID: String?
}

/// Builds the restart-resume plan for a persisted layouts file: which restored
/// tabs hosted a resumable AI CLI whose zmx session no longer exists (a machine
/// restart, or sessions terminated at quit). A live session means the surface
/// reattaches to the still-running CLI instead, so it never gets an intent.
nonisolated enum AgentSessionResume {
  /// Agents whose sessions Supacode can restore after a restart, by relaunching
  /// the CLI with its own resume flag. Every other program (shells, editors,
  /// servers) has nothing durable to resume, so restored tabs that hosted it
  /// come back as a fresh shell, exactly as today.
  static let resumableAgents: Set<SkillAgent> = [.claude, .droid, .cursor]

  /// The resume command typed into the restored surface's fresh shell, or nil
  /// when the agent has no relaunch shape. The session id is re-validated here:
  /// the value round-tripped through the layout file, and the command is typed
  /// verbatim into a shell, so only the inert charset may travel.
  static func command(for intent: ResumeIntent) -> String? {
    let sessionID = intent.sessionID.flatMap {
      AgentPresenceOSC.isValidSessionID($0) ? $0 : nil
    }
    switch intent.agent {
    case .claude:
      // `--continue` is scoped to the working directory, so the no-id fallback
      // (older hook installs, pre-feature layouts) still lands in the right
      // conversation rather than a picker.
      return sessionID.map { "claude --resume \($0)" } ?? "claude --continue"
    case .droid:
      // Bare `--resume` picks the globally last-modified session, which can
      // belong to another worktree; without an exact id the safer fallback is
      // a fresh session in the restored tab's directory.
      return sessionID.map { "droid --resume \($0)" } ?? "droid"
    case .cursor:
      return sessionID.map { "cursor-agent --resume \($0)" } ?? "cursor-agent"
    default:
      return nil
    }
  }

  /// Shell-ready `initialInput` for a restored surface's first spawn: the
  /// resume command plus Enter.
  static func initialInput(for intent: ResumeIntent) -> String? {
    command(for: intent).map { $0 + "\n" }
  }

  /// The agent worth resuming on one surface: the first record whose agent
  /// supports a restart resume. Records arrive sorted by agent rawValue, so
  /// the pick is deterministic. A surface realistically hosts one agent.
  static func intent(for records: [TerminalLayoutSnapshot.SurfaceAgentRecord]) -> ResumeIntent? {
    for record in records {
      guard let agent = SkillAgent(rawValue: record.agent), resumableAgents.contains(agent) else {
        continue
      }
      return ResumeIntent(agent: agent, sessionID: record.sessionID)
    }
    return nil
  }

  /// Per-surface resume intents for a whole persisted layouts file, gated by
  /// the setting and by each surface's zmx session being gone. `sessionExists`
  /// probes the surface's zmx session socket; absence after a restart is the
  /// only state that earns an intent.
  static func intents(
    in file: LayoutsFile,
    restoreEnabled: Bool,
    sessionExists: (UUID) -> Bool
  ) -> [UUID: ResumeIntent] {
    guard restoreEnabled else { return [:] }
    var result: [UUID: ResumeIntent] = [:]
    for record in file.worktrees.values {
      for pane in record.layout.panes {
        for tab in pane.tabs {
          let surfaceID = tab.content.id.rawValue
          guard case .terminal(let state) = tab.content.state else { continue }
          guard let agents = state.agents, let intent = intent(for: agents) else { continue }
          if !sessionExists(surfaceID) {
            result[surfaceID] = intent
          }
        }
      }
    }
    return result
  }
}

nonisolated extension PaneLayout {
  /// The same layout with each listed tab's terminal state carrying its resume
  /// intent; unlisted tabs keep their state untouched.
  func applyingResumeIntents(_ intents: [UUID: ResumeIntent]) -> PaneLayout {
    guard !intents.isEmpty else { return self }
    var result = self
    for paneIndex in result.panes.indices {
      for tabIndex in result.panes[paneIndex].tabs.indices {
        let tab = result.panes[paneIndex].tabs[tabIndex]
        guard let intent = intents[tab.content.id.rawValue],
          case .terminal(let state) = tab.content.state
        else { continue }
        result.panes[paneIndex].tabs[tabIndex].content = ContentSnapshot(
          id: tab.content.id,
          state: .terminal(
            TerminalContentState(
              workingDirectory: state.workingDirectory,
              agents: state.agents,
              frozenGrid: state.frozenGrid,
              resume: intent)))
      }
    }
    return result
  }
}
