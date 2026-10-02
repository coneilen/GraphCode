import GraphcodeKit
import SwiftUI

/// A sibling's mail, or an upstream handoff, shown where it landed in the conversation.
/// When Nod drafted a reply (`messagesOtherLoops` = Draft for me) it sits underneath with
/// Send reply · Edit · Answer myself, so a blocked loop is unblocked without leaving the pane.
struct NodInlineMailCard: View {
  let mail: NodInboundMail
  let draft: NodEvent.MailDraft?
  var receivedAt: Date?
  /// The draft as sent — the human may have edited it first.
  let onSendReply: (NodEvent.MailDraft, String) -> Void
  /// A reply written by the human, sent as this loop without Nod.
  let onAnswerMyself: (String) -> Void
  let onOpenTranscript: (UUID) -> Void

  private enum Composing: Equatable {
    case none
    case editingDraft
    case answeringMyself
  }

  @State private var composing = Composing.none
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if !mail.body.isEmpty {
        Text(mail.body)
          .font(.system(size: 12))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      if mail.kind == .mail { reply }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sheet))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.loopCardBorder))
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: mail.kind == .handoff ? "arrow.down.right.circle" : "envelope")
        .foregroundStyle(.white.opacity(0.7))
      Text(headline).font(.system(size: 11, weight: .semibold))
      if let receivedAt {
        Text("· \(receivedAt, style: .relative)")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.55))
      }
      Spacer()
      if let sender = mail.sender {
        Button("Open transcript") { onOpenTranscript(sender.id) }
          .buttonStyle(.link)
          .font(.system(size: 11))
      }
    }
  }

  private var headline: String {
    switch mail.kind {
    case .handoff: "Handoff in from \(mail.senderTitle)"
    case .mail: mail.isQuestion ? "\(mail.senderTitle) asks" : "\(mail.senderTitle) wrote"
    }
  }

  @ViewBuilder private var reply: some View {
    switch composing {
    case .none:
      if let draft {
        VStack(alignment: .leading, spacing: 6) {
          Text("Nod's draft:").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
          Text(draft.text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.draftField))
          HStack {
            Button("Send reply") { onSendReply(draft, draft.text) }
              .buttonStyle(.borderedProminent)
            Button("Edit") { begin(.editingDraft, with: draft.text) }
            Button("Answer myself") { begin(.answeringMyself, with: "") }
          }
          .controlSize(.small)
        }
      } else if mail.sender != nil {
        Button("Answer myself") { begin(.answeringMyself, with: "") }
          .controlSize(.small)
      }
    case .editingDraft, .answeringMyself:
      VStack(alignment: .leading, spacing: 6) {
        TextEditor(text: $text)
          .font(.system(size: 12))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 48, maxHeight: 140)
          .padding(4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Theme.draftField))
        HStack {
          Button("Send") { send() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Cancel") { composing = .none }
        }
        .controlSize(.small)
      }
    }
  }

  private func begin(_ mode: Composing, with initial: String) {
    text = initial
    composing = mode
  }

  private func send() {
    let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reply.isEmpty else { return }
    if composing == .editingDraft, let draft {
      onSendReply(draft, reply)
    } else {
      onAnswerMyself(reply)
    }
    composing = .none
  }
}
