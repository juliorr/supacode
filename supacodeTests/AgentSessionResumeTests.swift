import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - Command building.

struct AgentSessionResumeTests {
  @Test func claudeResumesTheExactSessionAndFallsBackToContinue() {
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .claude, sessionID: "a1b2c3d4-0000-4a3b-9c1e-abcdef012345"))
        == "claude --resume a1b2c3d4-0000-4a3b-9c1e-abcdef012345")
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .claude, sessionID: "session-abc123"))
        == "claude --resume session-abc123")
    // No id (older hook installs, legacy layouts): `--continue` is cwd-scoped,
    // so the fallback still lands in the right conversation.
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .claude, sessionID: nil))
        == "claude --continue")
  }

  @Test func droidResumesTheExactSessionAndFallsBackToFresh() {
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .droid, sessionID: "session-abc123"))
        == "droid --resume session-abc123")
    // Bare `--resume` picks the globally last-modified session, which can
    // belong to another worktree; a fresh session in the right directory is
    // the safer fallback.
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .droid, sessionID: nil)) == "droid")
  }

  @Test func cursorResumesTheExactChatAndFallsBackToFresh() {
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .cursor, sessionID: "chat-abc-123"))
        == "cursor-agent --resume chat-abc-123")
    #expect(
      AgentSessionResume.command(for: ResumeIntent(agent: .cursor, sessionID: nil))
        == "cursor-agent")
  }

  @Test func anInvalidSessionIDNeverReachesTheCommand() {
    // The id round-trips through a layout file and the command is typed
    // verbatim into a shell, so anything outside the inert charset falls back
    // instead of splicing shell syntax.
    let hostile = ["abc; rm -rf /", "$(pwd)", "a b c", "x' || true", "with\"quote", "", "héllo"]
    for id in hostile {
      let command = AgentSessionResume.command(for: ResumeIntent(agent: .claude, sessionID: id))
      #expect(command == "claude --continue", "hostile id \(id) produced \(command ?? "nil")")
    }
  }

  @Test func agentsOutsideTheResumeSetHaveNoCommand() {
    #expect(AgentSessionResume.command(for: ResumeIntent(agent: .codex, sessionID: "abc")) == nil)
    #expect(AgentSessionResume.command(for: ResumeIntent(agent: .grok, sessionID: nil)) == nil)
  }

  @Test func initialInputAppendsEnter() {
    #expect(
      AgentSessionResume.initialInput(for: ResumeIntent(agent: .droid, sessionID: "session-1"))
        == "droid --resume session-1\n")
    #expect(
      AgentSessionResume.initialInput(for: ResumeIntent(agent: .codex, sessionID: "session-1"))
        == nil)
  }

  // MARK: - Intent selection.

  @Test func intentPicksTheFirstResumableRecord() {
    // Records arrive sorted by agent rawValue; the pick is deterministic.
    let records = [
      TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "codex", pids: [1], activity: "busy"),
      TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [2], activity: "idle", sessionID: "abc"),
      TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "cursor", pids: [3], activity: "busy"),
    ]
    #expect(AgentSessionResume.intent(for: records) == ResumeIntent(agent: .claude, sessionID: "abc"))
  }

  @Test func intentIgnoresUnknownAgentsAndEmptyRecords() {
    #expect(
      AgentSessionResume.intent(
        for: [TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "atlas", pids: [1], activity: "busy")]
      ) == nil)
    #expect(AgentSessionResume.intent(for: []) == nil)
  }

  // MARK: - The launch-time plan.

  private static func agentLayout(
    paneID: PaneID, tabID: TabID, contentID: ContentID,
    agent: String?, sessionID: String? = nil
  ) -> PaneLayout {
    let state = TerminalContentState(
      workingDirectory: "/repo",
      agents: agent.map {
        [TerminalLayoutSnapshot.SurfaceAgentRecord(agent: $0, pids: [42], activity: "busy", sessionID: sessionID)]
      })
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(id: contentID, state: .terminal(state))
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private static func file(_ layouts: PaneLayout...) -> LayoutsFile {
    LayoutsFile(
      worktrees: Dictionary(
        uniqueKeysWithValues: layouts.enumerated().map { ("/tmp/repo\($0.offset)", LayoutRecord(layout: $0.element)) }))
  }

  @Test func planStaysEmptyWhenTheSettingIsOff() {
    let contentID = ContentID()
    let persisted = Self.file(
      Self.agentLayout(paneID: PaneID(), tabID: TabID(), contentID: contentID, agent: "claude", sessionID: "abc"))
    let intents = AgentSessionResume.intents(
      in: persisted, restoreEnabled: false, sessionExists: { _ in false })
    #expect(intents.isEmpty)
  }

  @Test func planSkipsSurfacesWhoseSessionSurvived() {
    let contentID = ContentID()
    let persisted = Self.file(
      Self.agentLayout(paneID: PaneID(), tabID: TabID(), contentID: contentID, agent: "claude", sessionID: "abc"))
    let intents = AgentSessionResume.intents(
      in: persisted, restoreEnabled: true, sessionExists: { _ in true })
    #expect(intents.isEmpty)
  }

  @Test func planResumesAgentTabsWhoseSessionIsGone() {
    let claudeSurface = ContentID()
    let shellSurface = ContentID()
    let otherAgentSurface = ContentID()
    let noAgentsLayout = Self.agentLayout(
      paneID: PaneID(), tabID: TabID(), contentID: shellSurface, agent: nil)
    let codexLayout = Self.agentLayout(
      paneID: PaneID(), tabID: TabID(), contentID: otherAgentSurface, agent: "codex")
    let claudeLayout = Self.agentLayout(
      paneID: PaneID(), tabID: TabID(), contentID: claudeSurface, agent: "claude", sessionID: "abc-123")
    let persisted = Self.file(noAgentsLayout, codexLayout, claudeLayout)

    let intents = AgentSessionResume.intents(
      in: persisted, restoreEnabled: true, sessionExists: { _ in false })

    #expect(intents.count == 1)
    #expect(intents[claudeSurface.rawValue] == ResumeIntent(agent: .claude, sessionID: "abc-123"))
    #expect(intents[shellSurface.rawValue] == nil)
    #expect(intents[otherAgentSurface.rawValue] == nil)
  }

  @Test func planIgnoresLayoutsWithoutAgentRecords() {
    // Legacy layouts predate the agents field entirely; they resume nothing.
    let contentID = ContentID()
    let layout = PaneLayout(
      tree: SplitTree(view: PaneID()),
      panes: [
        Pane(
          id: PaneID(),
          tabs: [
            TabItem(
              id: TabID(),
              title: "One",
              content: ContentSnapshot(
                id: contentID, state: .terminal(TerminalContentState(workingDirectory: "/repo"))))
          ]
        )
      ]
    )
    let intents = AgentSessionResume.intents(
      in: Self.file(layout), restoreEnabled: true, sessionExists: { _ in false })
    #expect(intents.isEmpty)
  }

  // MARK: - Layout overlay.

  @Test func overlayStagesIntentsOntoMatchingTabsOnly() {
    let claudeTab = TabID()
    let shellTab = TabID()
    let claudeContent = ContentID()
    let shellContent = ContentID()
    let paneID = PaneID()
    let terminalState = {
      TerminalContentState(
        workingDirectory: "/repo",
        agents: [
          TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy", sessionID: "abc")
        ])
    }
    let shellState = TerminalContentState(workingDirectory: "/repo")
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: claudeTab, title: "Claude",
              content: ContentSnapshot(id: claudeContent, state: .terminal(terminalState()))),
            TabItem(
              id: shellTab, title: "Shell",
              content: ContentSnapshot(id: shellContent, state: .terminal(shellState))),
          ],
          selectedTabID: claudeTab
        )
      ],
      focusedPaneID: paneID
    )

    let overlaid = layout.applyingResumeIntents([
      claudeContent.rawValue: ResumeIntent(agent: .claude, sessionID: "abc")
    ])

    guard
      case .terminal(let resumed)? = overlaid.panes[id: paneID]?.tabs[id: claudeTab]?.content.state
    else {
      Issue.record("Expected the claude tab to keep a terminal payload.")
      return
    }
    #expect(resumed.resume == ResumeIntent(agent: .claude, sessionID: "abc"))
    #expect(resumed.workingDirectory == "/repo")
    #expect(resumed.agents == terminalState().agents)
    guard
      case .terminal(let untouched)? = overlaid.panes[id: paneID]?.tabs[id: shellTab]?.content.state
    else {
      Issue.record("Expected the shell tab to keep a terminal payload.")
      return
    }
    #expect(untouched.resume == nil)
    #expect(untouched == shellState)
  }

  @Test func overlayWithoutIntentsReturnsTheLayoutUntouched() {
    let layout = Self.agentLayout(
      paneID: PaneID(), tabID: TabID(), contentID: ContentID(), agent: "claude", sessionID: "abc")
    #expect(layout.applyingResumeIntents([:]) == layout)
  }

  // MARK: - Persistence guards.

  @Test func resumeIntentNeverEncodesIntoPersistedState() throws {
    let state = TerminalContentState(
      workingDirectory: "/repo",
      resume: ResumeIntent(agent: .claude, sessionID: "abc"))
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: data)
    #expect(decoded.resume == nil)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("resume"))
  }

  @Test func persistenceStripsTheResumeIntentFromRecords() {
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let seedState = TerminalContentState(
      workingDirectory: "/repo",
      resume: ResumeIntent(agent: .claude, sessionID: "abc"))
    let layout = PaneLayout(
      tree: SplitTree(view: PaneID()),
      panes: [
        Pane(
          id: PaneID(),
          tabs: [
            TabItem(
              id: TabID(), title: "One",
              content: ContentSnapshot(id: contentID, state: .terminal(seedState)))
          ]
        )
      ]
    )
    let record = LayoutPersistence.record(for: layout, runtime: runtime)
    guard case .terminal(let saved)? = record.layout.panes.first?.tabs.first?.content.state else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(saved.resume == nil)
  }
}
