import Foundation

/// Fork as a new sibling loop: same type and goal as the source, its own worktree on a
/// branch cut from the source's, and the source's conversation up to one message as its
/// brief. The two then run at once, joined on the canvas by a dotted "forked from" line.
public struct NodFork: Equatable, Sendable {
  /// The worktree the app creates before sending the draft, mirroring the new-branch
  /// path the node form uses: `<repo's parent>/<repo>-<branch with / as ->`.
  public struct WorktreeRequest: Equatable, Sendable {
    public var repositoryPath: String
    public var worktreePath: String
    public var branch: String
    /// What the branch starts from: the source's branch, so the fork sees its edits.
    public var startPoint: String?

    public init(
      repositoryPath: String, worktreePath: String, branch: String, startPoint: String? = nil
    ) {
      self.repositoryPath = repositoryPath
      self.worktreePath = worktreePath
      self.branch = branch
      self.startPoint = startPoint
    }
  }

  public var draft: NodeDraft
  public var brief: NodBrief
  public var worktree: WorktreeRequest

  /// `conversationID` is the source's engine conversation (`conversation.json`), when
  /// the app has it; the runtime forks that conversation after `messageID`.
  public init(
    of source: LoopNode, in graph: LoopGraph, atMessage messageID: String,
    conversationID: String? = nil, approach: String? = nil, briefPath: String
  ) {
    let siblings = graph.nodes.filter {
      $0.lineage?.kind == .fork && $0.lineage?.sourceNodeID == source.id
    }
    let number = siblings.count + 2
    let title = "\(source.title)\(number)"
    let repository = source.worktreeBinding?.repositoryPath ?? graph.project.path
    let baseBranch = source.worktreeBinding?.branch
    let branchStem = baseBranch.flatMap { $0.isEmpty ? nil : $0 } ?? "nod/\(source.title)"
    let branch = "\(branchStem)-fork\(number)"
    let parentDirectory = (repository as NSString).deletingLastPathComponent
    let repositoryName = (repository as NSString).lastPathComponent
    let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
    worktree = WorktreeRequest(
      repositoryPath: repository,
      worktreePath: (parentDirectory as NSString)
        .appendingPathComponent("\(repositoryName)-\(safeBranch)"),
      branch: branch,
      startPoint: baseBranch.flatMap { $0.isEmpty ? nil : $0 })

    var text = "You are a fork of \(source.title), branched from its conversation."
    if let approach = approach?.trimmingCharacters(in: .whitespacesAndNewlines),
      !approach.isEmpty
    {
      text += " Take this approach: \(approach)"
    } else {
      text += " Try the approach it did not take."
    }
    text += " You work in your own worktree on \(branch); \(source.title) carries on in its own."
    brief = NodBrief(
      kind: .fork, fromNodeID: source.id, text: text,
      fork: NodBrief.ForkPoint(conversationID: conversationID, messageID: messageID))

    draft = NodeDraft(
      title: title,
      loopType: source.loopType == .composite ? .sketch : source.loopType,
      checkDescription: source.checkDescription,
      triggerPrompt: source.triggerPrompt,
      heartbeatIntervalSeconds: source.heartbeatIntervalSeconds,
      firstInstruction: source.firstInstruction,
      pausesBeforeWritesOnly: source.pausesBeforeWritesOnly,
      goal: source.goal,
      backend: .nod,
      modelTier: source.modelTier,
      lineage: LoopLineage(kind: .fork, sourceNodeID: source.id, briefPath: briefPath))
  }
}
