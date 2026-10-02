import ComposableArchitecture
import Foundation
import GraphcodeKit

/// Nod's chat pane: the transcript folded from `events.jsonl`, the work cards' decisions
/// and the composer, all sent back as `NodCommand`s over `control.sock`.
///
/// Everything the pane cannot do itself — open a shell tab, edit the goal, sign in, fork
/// into a sibling loop, run a plan as a Composite — goes up as a delegate action, so the
/// workspace and the graph layer decide what those mean.
@Reducer
struct NodChatFeature {
  @ObservableState
  struct State: Equatable {
    var nodeID: UUID
    var stateDirectory: URL
    var loopTitle: String
    var loopType: LoopType
    var branch: String?
    var goal: String?
    var editPolicy: NodSettings.EditPolicy = .reviewHunks

    var transcript = NodTranscript()
    /// The model picked from the chip since the session started; the log only names the
    /// model a run started on.
    var chosenModel: String?

    var draft = ""
    var attachments: [NodAttachment] = []
    /// Loops and files `@` can name, supplied by whoever knows the graph.
    var mentionCandidates: [NodMention] = []

    var expandedTools: Set<String> = []
    var expandedWork: Set<Int> = []
    var isCompactedExpanded = false
    var isGoalExpanded = false
    var forkMenuMessageID: String?
    var commentingHunkID: String?
    var hunkComment = ""
    var sendError: String?

    init(
      nodeID: UUID, stateDirectory: URL? = nil, loopTitle: String, loopType: LoopType,
      branch: String? = nil, goal: String? = nil
    ) {
      self.nodeID = nodeID
      self.stateDirectory = stateDirectory ?? NodStateDirectory.url(forNode: nodeID)
      self.loopTitle = loopTitle
      self.loopType = loopType
      self.branch = branch
      self.goal = goal
    }

    var model: String? { chosenModel ?? transcript.session?.model }

    var trigger: NodComposerTrigger? { NodComposerTrigger.detect(in: draft) }

    /// Failures and permission asks open on their own; everything else waits for a click.
    func isToolExpanded(_ card: NodTranscript.ToolCard) -> Bool {
      expandedTools.contains(card.call.callID) || card.status == .error
    }
  }

  enum Action: Equatable {
    case task
    case eventsReceived([NodEventRecord])

    case draftChanged(String)
    /// ⏎ — waits for the running turn to end.
    case returnPressed
    /// ⌘⏎ — lands at the next tool boundary without interrupting.
    case commandReturnPressed
    /// esc — closes an open menu first, and only then stops Nod.
    case escapePressed
    case stopTapped
    case slashCommandChosen(NodSlashCommand)
    /// `alternate` is ⇥'s other action: attach a running loop, message a finished one.
    case mentionChosen(NodMention, alternate: Bool)
    case attachmentAdded(NodAttachment)
    case attachmentRemoved(Int)
    case modelChosen(String)

    case toolToggled(callID: String)
    case workToggled(turn: Int)
    case compactedToggled
    case goalHeaderToggled
    case openInShellTabTapped(command: String)
    case hunkDecided(hunkID: String, NodHunkDecision)
    case hunkCommentStarted(hunkID: String)
    case hunkCommentChanged(String)
    case hunkCommentSubmitted
    case hunkCommentCancelled
    case permissionDecided(askID: String, NodPermissionDecision)
    case markGoalDoneTapped
    case editGoalTapped
    case forkMenuToggled(messageID: String?)
    case forkChosen(messageID: String, asSibling: Bool)
    case runPlanTapped(planID: String, mode: NodCommand.RunPlan.Mode)
    case sendDraftTapped(draftID: String, text: String)
    case compactNowTapped
    case signInTapped
    case raiseCapTapped
    case errorDismissed

    case commandFinished(NodCommandOutcome)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      /// "Open in zsh tab": type the command into a plain shell tab beside the chat.
      case openInShellTab(command: String)
      case editGoal
      case signIn
      case raiseSpendCap
      case forkAsSibling(messageID: String)
      case runPlanAsComposite(planID: String)
      /// `/handoff`, `/ask`, `/promote` — verbs that act on other loops.
      case graphCommand(name: String, argument: String)
      case messageLoop(UUID)
      case editPolicyChosen(NodSettings.EditPolicy)
    }
  }

  enum NodCommandOutcome: Equatable {
    case sent(NodCommand)
    case failed(String)
  }

  private enum CancelID { case events }

  @Dependency(\.nodClient) var nodClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        let directory = state.stateDirectory
        return .run { send in
          for await batch in nodClient.events(directory) {
            await send(.eventsReceived(batch))
          }
        }
        .cancellable(id: CancelID.events, cancelInFlight: true)

      case .eventsReceived(let records):
        for record in records { state.transcript.apply(record) }
        return .none

      case .draftChanged(let text):
        state.draft = text
        return .none

      case .returnPressed:
        return submit(&state, delivery: .queue)

      case .commandReturnPressed:
        return submit(&state, delivery: .steer)

      case .escapePressed:
        if state.forkMenuMessageID != nil {
          state.forkMenuMessageID = nil
          return .none
        }
        if state.commentingHunkID != nil {
          return .send(.hunkCommentCancelled)
        }
        if state.trigger != nil {
          state.draft = ""
          return .none
        }
        guard state.transcript.isRunning else { return .none }
        return command(.stop, state)

      case .stopTapped:
        return command(.stop, state)

      case .slashCommandChosen(let slash):
        state.draft = "/\(slash.name) "
        return .none

      case .mentionChosen(let mention, let alternate):
        replaceMentionQuery(&state, with: mention.title)
        switch mention.kind {
        case .loop(let id, let isRunning, _):
          if isRunning != alternate { return .send(.delegate(.messageLoop(id))) }
          state.attachments.append(
            NodAttachment(kind: .loopTranscript, reference: id.uuidString, label: mention.title))
        case .file(let path):
          state.attachments.append(NodAttachment(kind: .file, reference: path, label: nil))
        }
        return .none

      case .attachmentAdded(let attachment):
        guard !state.attachments.contains(attachment) else { return .none }
        state.attachments.append(attachment)
        return .none

      case .attachmentRemoved(let index):
        guard state.attachments.indices.contains(index) else { return .none }
        state.attachments.remove(at: index)
        return .none

      case .modelChosen(let model):
        return command(.setModel(.init(model: model)), state)

      case .toolToggled(let callID):
        state.expandedTools.formSymmetricDifference([callID])
        return .none

      case .workToggled(let turn):
        state.expandedWork.formSymmetricDifference([turn])
        return .none

      case .compactedToggled:
        state.isCompactedExpanded.toggle()
        return .none

      case .goalHeaderToggled:
        state.isGoalExpanded.toggle()
        return .none

      case .openInShellTabTapped(let command):
        return .send(.delegate(.openInShellTab(command: command)))

      case .hunkDecided(let hunkID, let decision):
        if decision == .comment { return .send(.hunkCommentStarted(hunkID: hunkID)) }
        return command(.resolveHunk(.init(hunkID: hunkID, decision: decision)), state)

      case .hunkCommentStarted(let hunkID):
        state.commentingHunkID = hunkID
        state.hunkComment = ""
        return .none

      case .hunkCommentChanged(let text):
        state.hunkComment = text
        return .none

      case .hunkCommentSubmitted:
        let note = state.hunkComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hunkID = state.commentingHunkID, !note.isEmpty else { return .none }
        state.commentingHunkID = nil
        state.hunkComment = ""
        return command(.resolveHunk(.init(hunkID: hunkID, decision: .comment, note: note)), state)

      case .hunkCommentCancelled:
        state.commentingHunkID = nil
        state.hunkComment = ""
        return .none

      case .permissionDecided(let askID, let decision):
        return command(.resolvePermission(.init(askID: askID, decision: decision)), state)

      case .markGoalDoneTapped:
        return command(.markGoalDone, state)

      case .editGoalTapped:
        return .send(.delegate(.editGoal))

      case .forkMenuToggled(let messageID):
        state.forkMenuMessageID = state.forkMenuMessageID == messageID ? nil : messageID
        return .none

      case .forkChosen(let messageID, let asSibling):
        state.forkMenuMessageID = nil
        if asSibling { return .send(.delegate(.forkAsSibling(messageID: messageID))) }
        return command(.fork(.init(messageID: messageID)), state)

      case .runPlanTapped(let planID, let mode):
        if mode == .composite { return .send(.delegate(.runPlanAsComposite(planID: planID))) }
        guard let plan = state.transcript.plan(id: planID) else { return .none }
        return command(.runPlan(.init(planID: planID, steps: plan.steps, mode: .here)), state)

      case .sendDraftTapped(let draftID, let text):
        return command(.sendDraft(.init(draftID: draftID, text: text)), state)

      case .compactNowTapped:
        return command(.compact, state)

      case .signInTapped:
        return .send(.delegate(.signIn))

      case .raiseCapTapped:
        return .send(.delegate(.raiseSpendCap))

      case .errorDismissed:
        state.sendError = nil
        return .none

      case .commandFinished(.sent(let command)):
        state.sendError = nil
        if case .setModel(let payload) = command { state.chosenModel = payload.model }
        return .none

      case .commandFinished(.failed(let message)):
        state.sendError = message
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func submit(_ state: inout State, delivery: NodDelivery) -> Effect<Action> {
    let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !state.attachments.isEmpty else { return .none }

    if text.hasPrefix("/") {
      let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
      let name = parts.first.map(String.init) ?? ""
      let argument = parts.count > 1 ? String(parts[1]) : ""
      switch name {
      case "compact":
        state.draft = ""
        return command(.compact, state)
      case "goal":
        state.draft = ""
        return .send(.delegate(.editGoal))
      case "fork":
        guard let messageID = state.transcript.lastAssistantMessageID else { return .none }
        state.draft = ""
        return .send(.forkMenuToggled(messageID: messageID))
      case "handoff", "ask", "promote":
        state.draft = ""
        return .send(.delegate(.graphCommand(name: name, argument: argument)))
      default:
        break
      }
    }

    let send = NodCommand.Send(text: text, delivery: delivery, attachments: state.attachments)
    state.draft = ""
    state.attachments = []
    return command(.send(send), state)
  }

  private func command(_ command: NodCommand, _ state: State) -> Effect<Action> {
    let directory = state.stateDirectory
    return .run { send in
      do {
        try await nodClient.send(directory, command)
        await send(.commandFinished(.sent(command)))
      } catch {
        await send(.commandFinished(.failed(error.localizedDescription)))
      }
    }
  }

  private func replaceMentionQuery(_ state: inout State, with title: String) {
    guard case .mention = state.trigger, let at = state.draft.lastIndex(of: "@") else { return }
    state.draft = String(state.draft[..<at]) + "@\(title) "
  }
}

extension NodTranscript {
  func plan(id: String) -> NodEvent.PlanProposed? {
    for turn in turns.reversed() {
      for item in turn.items.reversed() {
        if case .plan(let plan) = item, plan.planID == id { return plan }
      }
    }
    return nil
  }

  var lastAssistantMessageID: String? {
    for turn in turns.reversed() {
      for item in turn.items.reversed() {
        if case .text(let message) = item { return message.id }
      }
    }
    return nil
  }
}
