import Foundation

/// Plan → Composite: a Nod plan run as a composite whose children each take one area of
/// the code.
///
/// Steps are grouped by the area they touch, steps that share an area land in one child,
/// and a step that touches two areas joins them. The done-check step is not a child: it
/// becomes the composite's check. Every child inherits the planning conversation as its
/// brief, so none of them starts cold.
public struct NodCompositePlan: Equatable, Sendable {
  public struct Group: Equatable, Sendable {
    /// The area's name, also the child's title.
    public var area: String
    public var steps: [NodPlanStep]
  }

  public var title: String
  public var groups: [Group]
  public var doneChecks: [NodPlanStep]

  /// Directory names that say where code lives rather than what it is about.
  static let genericRoots: Set<String> = [
    "sources", "source", "src", "lib", "libs", "tests", "test", "spec", "specs",
    "packages", "pkg", "internal",
  ]

  public init(title: String, steps: [NodPlanStep]) {
    self.title = title
    doneChecks = steps.filter(\.doneCheck)
    groups = Self.group(steps.filter { !$0.doneCheck })
  }

  /// The area a repository-relative path belongs to: its first directory that is not a
  /// generic root, with a `…Tests` suffix folded onto the module it tests. A file at the
  /// root, or under generic roots only, has the empty area.
  public static func area(ofFile path: String) -> String {
    var directories = path.split(separator: "/").dropLast().map(String.init)
    while let first = directories.first,
      first == "." || genericRoots.contains(first.lowercased())
    {
      directories.removeFirst()
    }
    guard var area = directories.first else { return "" }
    for suffix in ["Tests", "Test", "-tests", "_tests"]
    where area.hasSuffix(suffix) && area.count > suffix.count {
      area.removeLast(suffix.count)
      break
    }
    return area
  }

  /// Steps without files follow the step before them, since a plan reads top to bottom;
  /// a leading step without files joins the first step that has some.
  static func group(_ steps: [NodPlanStep]) -> [Group] {
    guard !steps.isEmpty else { return [] }
    var areasByStep = steps.map { Set($0.files.map(area(ofFile:))) }
    if let firstWithFiles = areasByStep.firstIndex(where: { !$0.isEmpty }) {
      for index in areasByStep.indices where areasByStep[index].isEmpty {
        areasByStep[index] =
          index < firstWithFiles
          ? areasByStep[firstWithFiles] : areasByStep[index - 1]
      }
    } else {
      areasByStep = steps.map { _ in [""] }
    }

    var parent = Array(steps.indices)
    func root(_ index: Int) -> Int {
      var index = index
      while parent[index] != index { index = parent[index] }
      return index
    }
    var firstStepForArea: [String: Int] = [:]
    for (index, areas) in areasByStep.enumerated() {
      for area in areas {
        if let other = firstStepForArea[area] {
          let (a, b) = (root(index), root(other))
          if a != b { parent[max(a, b)] = min(a, b) }
        } else {
          firstStepForArea[area] = index
        }
      }
    }

    var order: [Int] = []
    var members: [Int: [Int]] = [:]
    for index in steps.indices {
      let group = root(index)
      if members[group] == nil { order.append(group) }
      members[group, default: []].append(index)
    }
    return order.map { group in
      let indices = members[group] ?? []
      let areas = indices.flatMap { areasByStep[$0] }
      var seen = Set<String>()
      let names = areas.filter { !$0.isEmpty && seen.insert($0).inserted }
      return Group(area: names.first ?? "", steps: indices.map { steps[$0] })
    }
  }

  /// The composite's check: what the done-check steps say, or nil without one.
  public var check: String? {
    let text = doneChecks.map(\.text).joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  /// The brief each child starts from: the whole plan with its own steps marked, and the
  /// planning loop's transcript attached.
  public func brief(for group: Group, plannedIn sourceNodeID: UUID) -> NodBrief {
    let mine = Set(group.steps.map(\.id))
    var lines = ["You are one loop of a composite running the plan \"\(title)\".", ""]
    var number = 0
    for step in groups.flatMap(\.steps) + doneChecks {
      number += 1
      let marker = mine.contains(step.id) ? "→" : step.doneCheck ? "✓" : " "
      let files = step.files.isEmpty ? "" : " (\(step.files.joined(separator: ", ")))"
      lines.append("\(marker) \(number). \(step.text)\(files)")
    }
    lines.append("")
    lines.append(
      "→ marks your steps. Other loops take the rest; ✓ is how the composite is checked.")
    if group.steps.contains(where: \.editedByHuman) {
      lines.append("Steps a human rewrote are theirs: do them as written.")
    }
    lines.append("The planning conversation is attached for context.")
    return NodBrief(
      kind: .compositeChild, fromNodeID: sourceNodeID, text: lines.joined(separator: "\n"),
      attachments: [NodAttachment(kind: .loopTranscript, reference: sourceNodeID.uuidString)])
  }

  /// The composite to create, plus the brief each child needs written at the path its
  /// lineage names. `briefPath` maps a child's draft id to where its brief will live.
  public func makeComposite(
    plannedIn source: LoopNode, briefPath: (UUID) -> String
  ) -> (draft: NodeDraft, briefs: [(path: String, brief: NodBrief)]) {
    var subGraph = LoopGraph(
      project: ProjectRef(path: "\(compositeTitle)-subgraph", name: compositeTitle))
    var briefs: [(String, NodBrief)] = []
    for (index, group) in groups.enumerated() {
      let id = UUID()
      let path = briefPath(id)
      briefs.append((path, brief(for: group, plannedIn: source.id)))
      let goal = group.steps.map { "- \($0.text)" }.joined(separator: "\n")
      subGraph.nodes.append(
        LoopNode(
          id: id,
          title: Self.childTitle(area: group.area, index: index, plan: title),
          loopType: .goalBased,
          goal: GoalSpec(summary: "Done when these steps are complete:\n\(goal)"),
          backend: .nod,
          worktreeBinding: source.worktreeBinding,
          lineage: LoopLineage(kind: .compositeChild, sourceNodeID: source.id, briefPath: path),
          state: .running))
    }
    let draft = NodeDraft(
      title: compositeTitle,
      loopType: .composite,
      checkDescription: check,
      worktree: source.worktreeBinding,
      subGraph: subGraph,
      createdBy: source.id)
    return (draft, briefs)
  }

  /// Composite titles are one word, like every loop title.
  var compositeTitle: String { LoopTitle.oneWord(title, fallback: "Plan") }

  static func childTitle(area: String, index: Int, plan: String) -> String {
    let word = LoopTitle.oneWord(area, fallback: "")
    return word.isEmpty ? "\(LoopTitle.oneWord(plan, fallback: "Plan"))\(index + 1)" : word
  }
}

/// CamelCase one-word titles, the shape the sidebar expects.
enum LoopTitle {
  static func oneWord(_ text: String, fallback: String) -> String {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .prefix(4)
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    let joined = words.joined()
    return joined.isEmpty ? fallback : joined
  }
}
