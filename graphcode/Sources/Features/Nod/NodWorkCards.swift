import AppKit
import GraphcodeKit
import SwiftUI

/// Design 3a: one line when collapsed — verb, subject, summary — and the output with
/// "Open in zsh tab" and "Copy output" when open.
struct NodToolCardView: View {
  let card: NodTranscript.ToolCard
  let isExpanded: Bool
  let onToggle: () -> Void
  let onOpenInShell: (String) -> Void

  private var verb: NodToolVerb { NodToolVerb(tool: card.call.tool) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggle) {
        HStack(spacing: 8) {
          if card.status == .running {
            NodSpinner()
          } else {
            Text(isExpanded ? "▾" : "▸").font(.system(size: 9))
          }
          Text(verb == .other ? card.call.tool : verb.label).foregroundStyle(NodStyle.secondary)
          Text(subject).font(NodStyle.mono).lineLimit(1).truncationMode(.middle)
          if let summary = card.result?.summary, !summary.isEmpty {
            Text("· \(summary)")
              .foregroundStyle(card.status == .error ? NodStyle.failed : NodStyle.muted)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          if let ms = card.result?.durationMs {
            Text(NodChatPresentation.duration(ms: ms))
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(NodStyle.muted)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        expanded
      }
    }
  }

  /// The title minus a leading verb that repeats the tool's name — `Search "UsageGate"`
  /// under a `Grep` tool reads as its subject, `Read UsageGate.swift` as `UsageGate.swift`.
  private var subject: String {
    let title = card.call.title
    for prefix in [card.call.tool, verb.label] where title.hasPrefix(prefix + " ") {
      return String(title.dropFirst(prefix.count + 1))
    }
    return title
  }

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let output = card.result?.output, !output.isEmpty {
        ScrollView {
          Text(output)
            .font(NodStyle.mono)
            .foregroundStyle(NodStyle.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 14) {
        if verb == .shell {
          Button("Open in zsh tab") { onOpenInShell(subject) }
        }
        if let output = card.result?.output, !output.isEmpty {
          Button("Copy output") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
          }
        }
        Spacer()
      }
      .buttonStyle(NodLinkButtonStyle())
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .overlay(alignment: .top) { Rectangle().fill(NodStyle.hairline).frame(height: 1) }
    }
    .background(RoundedRectangle(cornerRadius: 8).fill(NodStyle.cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(NodStyle.hairline, lineWidth: 1))
    .padding(.top, 2)
    .padding(.bottom, 4)
  }
}

/// Design 1b's Work block: a turn's tool calls folded to one row of counts once there are
/// more than five, opening to one line per call.
struct NodWorkBlockView: View {
  let summary: NodWorkSummary
  let isExpanded: Bool
  let onToggle: () -> Void
  let toolCard: (NodTranscript.ToolCard) -> NodToolCardView

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggle) {
        HStack(spacing: 8) {
          Text(isExpanded ? "▾" : "▸").font(.system(size: 9)).foregroundStyle(NodStyle.muted)
          Text("Work").font(.system(size: 12, weight: .semibold)).foregroundStyle(NodStyle.ink)
          Text(summary.line).foregroundStyle(NodStyle.muted)
          if let running = summary.running {
            Text("· running \(running.call.title)")
              .foregroundStyle(NodStyle.actionInk)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          if summary.durationMs > 0 {
            Text(NodChatPresentation.duration(ms: summary.durationMs))
              .foregroundStyle(NodStyle.muted)
          }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(summary.tools, id: \.call.callID) { tool in
            toolCard(tool)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Rectangle().fill(NodStyle.hairline).frame(height: 1) }
      }
    }
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(NodStyle.hairline, lineWidth: 1))
  }
}

/// Design 3b: one staged hunk — written to the loop's worktree only on Accept.
struct NodHunkCardView: View {
  let card: NodTranscript.HunkCard
  let isCommenting: Bool
  @Binding var comment: String
  let onDecide: (NodHunkDecision) -> Void
  let onSubmitComment: () -> Void
  let onCancelComment: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(card.staged.file).font(NodStyle.mono).foregroundStyle(NodStyle.ink).lineLimit(1)
          .truncationMode(.head)
        Text("+\(card.staged.added)").foregroundStyle(NodStyle.met)
        if card.staged.removed > 0 {
          Text("−\(card.staged.removed)").foregroundStyle(NodStyle.failed)
        }
        Spacer(minLength: 8)
        trailing
      }
      .font(.system(size: 11))
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .overlay(alignment: .bottom) { Rectangle().fill(NodStyle.hairline).frame(height: 1) }

      NodDiffView(header: card.staged.header, diff: card.staged.diff)
        .opacity(card.decision == .reject ? 0.45 : 1)

      if isCommenting {
        commentField
      } else if let note = card.resolution?.note, card.decision == .comment {
        Text("Sent back: \(note)")
          .font(.system(size: 11.5))
          .foregroundStyle(NodStyle.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
      }
    }
    .background(RoundedRectangle(cornerRadius: 10).fill(NodStyle.cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(NodStyle.hairline, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var trailing: some View {
    switch card.decision {
    case .accept:
      Text(card.staged.autoAccepted && card.resolution == nil ? "✓ auto-accepted" : "✓ accepted")
        .foregroundStyle(NodStyle.met)
    case .reject:
      Text("rejected").foregroundStyle(NodStyle.muted)
    case .comment:
      Text("sent back").foregroundStyle(NodStyle.attentionInk)
    case nil:
      HStack(spacing: 6) {
        Button("Reject") { onDecide(.reject) }.buttonStyle(NodButtonStyle(weight: .plain))
        Button("Comment") { onDecide(.comment) }.buttonStyle(NodButtonStyle(weight: .secondary))
        Button("Accept") { onDecide(.accept) }.buttonStyle(NodButtonStyle(weight: .primary))
      }
    }
  }

  private var commentField: some View {
    HStack(spacing: 8) {
      TextField("Send it back with a note…", text: $comment)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .onSubmit(onSubmitComment)
      Button("Cancel", action: onCancelComment).buttonStyle(NodButtonStyle(weight: .plain))
      Button("Send back", action: onSubmitComment).buttonStyle(NodButtonStyle(weight: .primary))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .overlay(alignment: .top) { Rectangle().fill(NodStyle.hairline).frame(height: 1) }
  }
}

struct NodDiffView: View {
  let header: String
  let diff: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      line(header.hasPrefix("@@") ? header : "@@ \(header)", kind: .header)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, text in
        line(text, kind: Kind(text))
      }
    }
    .font(NodStyle.mono)
    .padding(.vertical, 4)
  }

  /// The hunk's body without the diff's own file and range headers, which the card already
  /// shows above it.
  private var lines: [String] {
    diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
      !$0.hasPrefix("@@") && !$0.hasPrefix("+++") && !$0.hasPrefix("---") && !$0.isEmpty
    }
  }

  private enum Kind {
    case header, added, removed, context

    init(_ text: String) {
      if text.hasPrefix("+") {
        self = .added
      } else if text.hasPrefix("-") {
        self = .removed
      } else {
        self = .context
      }
    }
  }

  private func line(_ text: String, kind: Kind) -> some View {
    Text(text)
      .foregroundStyle(foreground(kind))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 1)
      .background(background(kind))
      .lineLimit(1)
  }

  private func foreground(_ kind: Kind) -> Color {
    switch kind {
    case .header: return NodStyle.muted
    case .added: return NodStyle.added
    case .removed: return NodStyle.removed
    case .context: return Color.white.opacity(0.6)
    }
  }

  private func background(_ kind: Kind) -> Color {
    switch kind {
    case .added: return NodStyle.met.opacity(0.12)
    case .removed: return Color(red: 1, green: 0.271, blue: 0.227).opacity(0.12)
    case .header, .context: return .clear
    }
  }
}

/// Design 3c: a real "needs you" state, in the same orange as a CLI loop waiting on you.
struct NodPermissionCardView: View {
  let card: NodTranscript.PermissionCard
  /// The project's name, for "Always in <project>".
  let projectName: String
  let onDecide: (NodPermissionDecision) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Circle().fill(card.decision == nil ? NodStyle.attention : NodStyle.muted)
          .frame(width: 7, height: 7)
        Text(Self.title(card.ask.kind))
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(NodStyle.ink)
      }
      Text(card.ask.subject)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
        .textSelection(.enabled)
      if !card.ask.reason.isEmpty {
        Text(card.ask.reason)
          .font(.system(size: 12))
          .foregroundStyle(Color.white.opacity(0.65))
          .fixedSize(horizontal: false, vertical: true)
      }
      if let decision = card.decision {
        Text(Self.resolvedLabel(decision))
          .font(.system(size: 11.5))
          .foregroundStyle(decision == .deny ? NodStyle.muted : NodStyle.met)
      } else {
        HStack(spacing: 7) {
          Button("Allow once") { onDecide(.allowOnce) }
            .buttonStyle(NodButtonStyle(weight: .primary))
          Button("Always in \(projectName)") { onDecide(.alwaysAllow) }
            .buttonStyle(NodButtonStyle(weight: .secondary))
          Spacer()
          Button("Deny") { onDecide(.deny) }.buttonStyle(NodButtonStyle(weight: .plain))
        }
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(card.decision == nil ? NodStyle.attention.opacity(0.07) : Color.white.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          card.decision == nil ? NodStyle.attention.opacity(0.4) : NodStyle.hairline, lineWidth: 1)
    )
  }

  static func title(_ kind: NodPermissionKind) -> String {
    switch kind {
    case .shell: return "Nod wants to run a command"
    case .network: return "Nod wants to reach the network"
    case .editOutsideWorktree: return "Nod wants to edit outside its worktree"
    case .messageLoop: return "Nod wants to message another loop"
    case .mcpTool: return "Nod wants to use an MCP tool"
    }
  }

  static func resolvedLabel(_ decision: NodPermissionDecision) -> String {
    switch decision {
    case .allowOnce: return "✓ Allowed once"
    case .alwaysAllow: return "✓ Always allowed"
    case .deny: return "Denied"
    }
  }
}

/// Design 3d: the goal split into clauses, each with its evidence, and the way out when
/// the evaluator is wrong.
struct NodGoalCheckCardView: View {
  let check: NodEvent.GoalCheck
  let goalTint: Color
  let onMarkDone: () -> Void
  let onEditGoal: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 2).fill(goalTint).frame(width: 8, height: 8)
        Text("Goal check · after turn \(check.turn)")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(NodStyle.ink)
        Spacer()
        Text("evaluator: \(NodChatPresentation.modelLabel(check.evaluatorModel))")
          .font(.system(size: 11))
          .foregroundStyle(NodStyle.muted)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .overlay(alignment: .bottom) { Rectangle().fill(goalTint.opacity(0.2)).frame(height: 1) }

      NodGoalClauseList(clauses: check.clauses)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      HStack(spacing: 10) {
        Text(check.met ? "Goal holds. Nod stops here." : "Not yet. Nod carries on.")
          .foregroundStyle(Color.white.opacity(0.65))
        Spacer()
        if !check.met {
          Button("Mark done anyway", action: onMarkDone)
        }
        Button("Edit goal", action: onEditGoal)
      }
      .font(.system(size: 11.5))
      .buttonStyle(NodLinkButtonStyle())
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .overlay(alignment: .top) { Rectangle().fill(goalTint.opacity(0.2)).frame(height: 1) }
    }
    .background(RoundedRectangle(cornerRadius: 10).fill(goalTint.opacity(0.06)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(goalTint.opacity(0.4), lineWidth: 1))
  }
}

struct NodGoalClauseList: View {
  let clauses: [NodGoalClause]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(clauses.enumerated()), id: \.offset) { _, clause in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(clause.met ? "✓" : "○")
            .foregroundStyle(clause.met ? NodStyle.met : NodStyle.attention)
          Text(clause.text).foregroundStyle(Color.white.opacity(0.82))
          Spacer(minLength: 8)
          if let evidence = clause.evidence {
            Text(evidence)
              .foregroundStyle(clause.met ? NodStyle.muted : NodStyle.attentionInk.opacity(0.9))
              .multilineTextAlignment(.trailing)
          }
        }
        .font(.system(size: 12))
      }
    }
  }
}

/// Design 3e: a branch stays inside the loop; a sibling gets its own worktree and card.
struct NodForkMenuView: View {
  var canBranch = true
  let onBranch: () -> Void
  let onSibling: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Fork as")
        .font(.system(size: 10.5, weight: .bold))
        .textCase(.uppercase)
        .foregroundStyle(NodStyle.muted)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
      option(
        "Branch in this loop",
        canBranch
          ? "Try the other approach. Switch with ‹ 1 / 2 › on the message."
          : "Not available in this version of Nod yet.",
        action: onBranch
      )
      .disabled(!canBranch)
      .opacity(canBranch ? 1 : 0.5)
      option(
        "New sibling loop", "Its own worktree and its own card on the canvas, so both run at once.",
        action: onSibling)
    }
    .padding(.bottom, 6)
    .frame(width: 300, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.17)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
  }

  private func option(_ title: String, _ detail: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(NodStyle.ink)
        Text(detail).font(.system(size: 11)).foregroundStyle(NodStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// The pane's own plan card, until the graph layer's plan mode replaces it through
/// `NodGraphSlots.plan`.
struct NodPlanCardView: View {
  let plan: NodEvent.PlanProposed
  var canRun = true
  let onRun: (NodCommand.RunPlan.Mode) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Plan").font(.system(size: 11, weight: .bold)).textCase(.uppercase)
          .foregroundStyle(NodStyle.muted)
        Text(plan.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(NodStyle.ink)
      }
      ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(index + 1)").font(NodStyle.mono).foregroundStyle(NodStyle.muted)
          Text(step.text).font(.system(size: 12)).foregroundStyle(NodStyle.body)
          Spacer()
          if let size = step.size {
            Text(size.rawValue).font(.system(size: 10.5)).foregroundStyle(NodStyle.muted)
          }
        }
      }
      HStack {
        Spacer()
        Button("Run as Composite") { onRun(.composite) }.buttonStyle(NodButtonStyle())
        Button("Run here") { onRun(.here) }.buttonStyle(NodButtonStyle(weight: .primary))
          .disabled(!canRun)
          .opacity(canRun ? 1 : 0.5)
          .help(canRun ? "" : "Not available in this version of Nod yet.")
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(NodStyle.cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(NodStyle.hairline, lineWidth: 1))
  }
}

/// The pane's own draft card, until the graph layer's inline mail replaces it through
/// `NodGraphSlots.mailDraft`.
struct NodMailDraftCardView: View {
  let draft: NodEvent.MailDraft
  var canSend = true
  let onSend: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nod's draft reply").font(.system(size: 11.5)).foregroundStyle(NodStyle.muted)
      Text(draft.text).font(.system(size: 12.5)).foregroundStyle(NodStyle.body)
        .textSelection(.enabled)
      HStack {
        Spacer()
        Button("Send reply", action: onSend).buttonStyle(NodButtonStyle(weight: .primary))
          .disabled(!canSend)
          .opacity(canSend ? 1 : 0.5)
          .help(canSend ? "" : "Not available in this version of Nod yet.")
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(NodStyle.hairline, lineWidth: 1))
  }
}

/// The design's running dot: a grey ring with a blue head. Static, so a headless render
/// and a reduced-motion screen draw the same thing.
struct NodSpinner: View {
  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)
      Circle().trim(from: 0, to: 0.25).stroke(NodStyle.action, lineWidth: 1.5)
    }
    .frame(width: 10, height: 10)
  }
}
