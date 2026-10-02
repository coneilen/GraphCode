import Foundation

/// The plan card's editable copy of a `planProposed`. Nod sees a human's edits as edits:
/// a rewritten or added step is marked `editedByHuman`, so Nod does not argue it back.
public struct NodEditablePlan: Equatable, Sendable {
  public var planID: String
  public var title: String
  public var steps: [NodPlanStep]

  public init(planID: String, title: String, steps: [NodPlanStep]) {
    self.planID = planID
    self.title = title
    self.steps = steps
  }

  public init(_ proposed: NodEvent.PlanProposed) {
    self.init(planID: proposed.planID, title: proposed.title, steps: proposed.steps)
  }

  public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    let moving = source.sorted().map { steps[$0] }
    let before = source.filter { $0 < destination }.count
    for index in source.sorted(by: >) { steps.remove(at: index) }
    steps.insert(contentsOf: moving, at: destination - before)
  }

  /// Unchanged text is not an edit, so clicking into a step and out again leaves it Nod's.
  public mutating func rewrite(stepID: String, to text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let index = steps.firstIndex(where: { $0.id == stepID }), !text.isEmpty,
      steps[index].text != text
    else { return }
    steps[index].text = text
    steps[index].editedByHuman = true
  }

  public mutating func remove(stepID: String) {
    steps.removeAll { $0.id == stepID }
  }

  public mutating func add(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let ids = Set(steps.map(\.id))
    var number = steps.count + 1
    while ids.contains("h\(number)") { number += 1 }
    steps.append(NodPlanStep(id: "h\(number)", text: text, editedByHuman: true))
  }

  public mutating func toggleDoneCheck(stepID: String) {
    guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
    steps[index].doneCheck.toggle()
  }

  /// How many loops Run as Composite would make — the button's count.
  public var compositeLoopCount: Int {
    NodCompositePlan(title: title, steps: steps).groups.count
  }

  public func runCommand(_ mode: NodCommand.RunPlan.Mode) -> NodCommand {
    .runPlan(NodCommand.RunPlan(planID: planID, steps: steps, mode: mode))
  }
}
