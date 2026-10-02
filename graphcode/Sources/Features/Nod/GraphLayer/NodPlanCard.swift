import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// A `planProposed`, as an editable list: drag to reorder, click a step to rewrite it,
/// ⌫ or the × to drop one, ＋ to add. Rewritten and added steps are marked as the human's.
/// Run here pins the plan in this loop; Run as Composite makes one child loop per area.
struct NodPlanCard: View {
  @Binding var plan: NodEditablePlan
  let onRunHere: () -> Void
  let onRunAsComposite: () -> Void
  let onKeepRefining: () -> Void

  @State private var editingStepID: String?
  @State private var editText = ""
  @State private var newStep = ""
  @State private var draggingStepID: String?
  @FocusState private var focusedStepID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("Plan").font(.system(size: 11, weight: .semibold)).foregroundStyle(
          .white.opacity(0.55))
        Text(plan.title).font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("read-only until you run it")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.55))
      }
      VStack(spacing: 2) {
        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
          row(step, number: index + 1)
            .onDrag {
              draggingStepID = step.id
              return NSItemProvider(object: step.id as NSString)
            }
            .onDrop(
              of: [UTType.text],
              delegate: StepDropDelegate(
                targetID: step.id, plan: $plan, draggingStepID: $draggingStepID))
        }
      }
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        TextField("Add step", text: $newStep)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .onSubmit {
            plan.add(newStep)
            newStep = ""
          }
      }
      .padding(.horizontal, 6)
      HStack {
        Button("Keep refining", action: onKeepRefining)
        Spacer()
        Button("Run as Composite · \(plan.compositeLoopCount) loops", action: onRunAsComposite)
          .disabled(plan.compositeLoopCount == 0)
        Button("Run here", action: onRunHere)
          .buttonStyle(.borderedProminent)
          .disabled(plan.steps.isEmpty)
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sheet))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.loopCardBorder))
  }

  @ViewBuilder
  private func row(_ step: NodPlanStep, number: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("⋮⋮").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        .help("Drag to reorder")
      Text("\(number)").font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
      VStack(alignment: .leading, spacing: 2) {
        if editingStepID == step.id {
          TextField("Step", text: $editText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focusedStepID, equals: step.id)
            .onSubmit { commitEdit() }
            .onChange(of: focusedStepID) { _, focused in
              if focused != step.id { commitEdit() }
            }
            .onExitCommand { editingStepID = nil }
        } else {
          Text(step.text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { beginEdit(step) }
        }
        if let caption = caption(for: step) {
          Text(caption).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
      }
      Spacer(minLength: 4)
      if let size = step.size {
        Text(size.rawValue).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
      }
      Button {
        plan.toggleDoneCheck(stepID: step.id)
      } label: {
        Image(systemName: step.doneCheck ? "checkmark.seal.fill" : "checkmark.seal")
      }
      .buttonStyle(.plain)
      .foregroundStyle(step.doneCheck ? LoopType.goalBased.accent : .white.opacity(0.4))
      .help(step.doneCheck ? "The done check — not a loop of its own" : "Make this the done check")
      Button {
        plan.remove(stepID: step.id)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white.opacity(0.4))
      .help("Drop this step")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(draggingStepID == step.id ? Theme.tabSelectedBackground : .clear)
    )
    .focusable(editingStepID != step.id)
    .onDeleteCommand { plan.remove(stepID: step.id) }
  }

  private func caption(for step: NodPlanStep) -> String? {
    var parts = step.files.map { ($0 as NSString).lastPathComponent }
    if step.editedByHuman { parts.append("you edited this") }
    if step.doneCheck { parts.append("done check") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func beginEdit(_ step: NodPlanStep) {
    editText = step.text
    editingStepID = step.id
    focusedStepID = step.id
  }

  private func commitEdit() {
    guard let id = editingStepID else { return }
    plan.rewrite(stepID: id, to: editText)
    editingStepID = nil
  }
}

private struct StepDropDelegate: DropDelegate {
  let targetID: String
  @Binding var plan: NodEditablePlan
  @Binding var draggingStepID: String?

  func dropEntered(info: DropInfo) {
    guard let dragging = draggingStepID, dragging != targetID,
      let from = plan.steps.firstIndex(where: { $0.id == dragging }),
      let to = plan.steps.firstIndex(where: { $0.id == targetID })
    else { return }
    withAnimation(.easeOut(duration: 0.12)) {
      plan.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    draggingStepID = nil
    return true
  }
}
