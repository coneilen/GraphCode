import ComposableArchitecture
import GraphcodeKit
import SwiftUI

extension NodGraphSlots {
  /// The graph layer for one loop's chat, from the workspace's node and graph: who it sits
  /// between, mail from siblings with Nod's draft underneath, the handoff once its goal
  /// holds, and plans as editable cards. A loop with no edges gets the plain pane.
  @MainActor
  static func workspace(
    _ store: StoreOf<LoopWorkspaceFeature>, chat: StoreOf<NodChatFeature>
  ) -> NodGraphSlots {
    let node = store.node
    let graph = store.graph
    let transcript = chat.transcript
    let inbound = NodGraphLayerModel.inboundMail(in: transcript, nodeID: node.id, graph: graph)
    let open: (UUID) -> Void = { store.send(.railTargetTapped($0)) }

    return NodGraphSlots(
      contextStrip: {
        AnyView(NodContextStrip(context: NodGraphContext(nodeID: node.id, in: graph), onOpen: open))
      },
      mailDraft: { draft in
        if let inReplyTo = draft.inReplyTo, inbound[inReplyTo] != nil {
          return AnyView(EmptyView())
        }
        return AnyView(
          NodMailDraftCardView(
            draft: draft, canSend: !chat.unavailableCommands.contains("sendDraft")
          ) {
            chat.send(.sendDraftTapped(draftID: draft.draftID, text: draft.text))
          })
      },
      plan: { proposed in
        AnyView(
          NodPlanCard(
            plan: Binding(
              get: { store.nodPlanEdits[proposed.planID] ?? NodEditablePlan(proposed) },
              set: { store.send(.nodPlanEdited($0)) }),
            onRunHere: {
              let steps = store.nodPlanEdits[proposed.planID]?.steps ?? proposed.steps
              chat.send(.runPlanTapped(planID: proposed.planID, mode: .here, steps: steps))
            },
            onRunAsComposite: {
              chat.send(.runPlanTapped(planID: proposed.planID, mode: .composite))
            },
            onKeepRefining: {
              if chat.draft.isEmpty { chat.send(.draftChanged("About the plan: ")) }
            }))
      },
      inboundMessage: { message, _ in
        guard let mail = inbound[message.id] else { return nil }
        return AnyView(
          NodInlineMailCard(
            mail: mail, draft: transcript.mailDraft(inReplyTo: mail.messageID),
            onSendReply: { draft, text in
              chat.send(.sendDraftTapped(draftID: draft.draftID, text: text))
            },
            onAnswerMyself: { store.send(.nodMailAnswered(mail, text: $0)) },
            onOpenTranscript: open))
      },
      afterGoalCheck: { check in
        guard
          let offer = NodGraphLayerModel.handoffOffer(
            after: check, in: transcript, node: node, graph: graph,
            settled: store.nodSettledHandoffs)
        else { return nil }
        return AnyView(
          NodHandoffOfferView(
            offer: offer,
            onHandOff: { store.send(.nodHandoffTapped(offer, brief: $0, turn: check.turn)) },
            onDismiss: { store.send(.nodHandoffDismissed(turn: check.turn)) }))
      })
  }
}

/// The decisions behind the slots, apart from the views so they can be tested as values.
enum NodGraphLayerModel {
  /// Turn prompts that came from another loop, by message id.
  static func inboundMail(in transcript: NodTranscript, nodeID: UUID, graph: LoopGraph)
    -> [String: NodInboundMail]
  {
    var mail: [String: NodInboundMail] = [:]
    for turn in transcript.turns {
      guard let prompt = turn.prompt,
        let classified = NodInboundMail.classify(prompt, nodeID: nodeID, in: graph)
      else { continue }
      mail[prompt.id] = classified
    }
    return mail
  }

  /// Offered under the newest goal check only, while the loop is still open and the offer
  /// has been neither taken nor put away.
  static func handoffOffer(
    after check: NodEvent.GoalCheck, in transcript: NodTranscript, node: LoopNode,
    graph: LoopGraph, settled: Set<Int>
  ) -> NodHandoffOffer? {
    guard check == transcript.lastGoalCheck, !settled.contains(check.turn), !node.isResolved
    else { return nil }
    return NodHandoffOffer.make(
      check: check, nodeID: node.id, in: graph,
      summaries: transcript.lastAssistantText.map { [$0] } ?? [])
  }
}

extension NodTranscript {
  func mailDraft(inReplyTo messageID: String) -> NodEvent.MailDraft? {
    for turn in turns.reversed() {
      for item in turn.items.reversed() {
        if case .mailDraft(let draft) = item, draft.inReplyTo == messageID { return draft }
      }
    }
    return nil
  }

  var lastAssistantText: String? {
    for turn in turns.reversed() {
      for item in turn.items.reversed() {
        if case .text(let message) = item, message.isFinal { return message.text }
      }
    }
    return nil
  }
}

/// Edit goal, from the goal-check card or `/goal`. A sheet because the terminal beside it
/// holds first responder and an inline field would never get the keyboard.
struct NodGoalEditSheet: View {
  @Bindable var store: StoreOf<LoopWorkspaceFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Edit goal").font(.headline)
      Text("Done when…").font(.caption).foregroundStyle(.secondary)
      TextEditor(
        text: Binding(
          get: { store.nodGoalDraft ?? "" }, set: { store.send(.nodGoalDraftChanged($0)) })
      )
      .font(.system(size: 13))
      .frame(minWidth: 420, minHeight: 90)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.nodGoalDraftChanged(nil)) }
          .keyboardShortcut(.cancelAction)
        Button("Save") { store.send(.nodGoalSaved) }
          .keyboardShortcut(.defaultAction)
          .disabled(
            (store.nodGoalDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
  }
}

extension View {
  func nodGoalEditSheet(_ store: StoreOf<LoopWorkspaceFeature>) -> some View {
    sheet(
      isPresented: Binding(
        get: { store.nodGoalDraft != nil },
        set: { if !$0 { store.send(.nodGoalDraftChanged(nil)) } })
    ) {
      NodGoalEditSheet(store: store)
    }
  }
}
