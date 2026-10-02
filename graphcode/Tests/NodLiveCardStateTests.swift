import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

@MainActor
@Suite
struct NodLiveCardStateTests {
  private static func ask(answerable: Bool) -> NodEvent.PermissionAsked {
    NodEvent.PermissionAsked(
      askID: "a1", kind: .shell, subject: "swift package resolve", reason: "network",
      answerableFromCard: answerable)
  }

  @Test
  func cardStateBecomesTheCardsDetail() throws {
    #expect(NodCardDetail(NodCardState()) == nil)
    let detail = try #require(
      NodCardDetail(
        NodCardState(
          goalProgress: NodGoalProgress(met: 1, total: 2),
          pendingAsk: Self.ask(answerable: true))))
    #expect(detail.goalMet == 1)
    #expect(detail.goalTotal == 2)
    #expect(
      detail.ask
        == NodCardDetail.Ask(
          askID: "a1", kind: .shell, subject: "swift package resolve", answerableFromCard: true))
  }

  @Test
  func theFoldIsRedoneOnlyWhenTheLogMoves() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("nod-card-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let folds = LockIsolated(0)
    let live = NodLiveCardState(
      eventsFile: { _ in file },
      fold: { _ in
        folds.withValue { $0 += 1 }
        let records = NodProtocol.records(fromJSONLines: (try? Data(contentsOf: file)) ?? Data())
        return NodSessionFold(records: records).cardState
      })
    let node = NodGraphLayerFixture.me

    #expect(live.cardDetail(for: node) == nil)
    #expect(folds.value == 0)

    var log = NodLog()
    log.session()
    log.goalCheck(turn: 1, met: false, clauses: [("a", true, nil), ("b", false, nil)])
    try log.jsonLines.write(to: file)
    #expect(live.cardDetail(for: node)?.goalMet == 1)
    #expect(live.cardDetail(for: node)?.goalTotal == 2)
    #expect(folds.value == 1)

    log.ask("a1", subject: "swift package resolve", reason: "network")
    try log.jsonLines.write(to: file)
    #expect(live.cardDetail(for: node)?.ask?.askID == "a1")
    #expect(folds.value == 2)
  }

  @Test
  func allowOnceResolvesTheAskOverTheLoopsSocket() async {
    let sent = LockIsolated<[(NodCommand, UUID)]>([])
    let live = NodLiveCardState(
      eventsFile: { _ in URL(fileURLWithPath: "/nonexistent") }, fold: { _ in NodCardState() },
      resolve: { command, id in sent.withValue { $0.append((command, id)) } })
    let id = UUID()
    live.allowOnce(nodeID: id, askID: "a1")
    for _ in 0..<100 where sent.value.isEmpty { await Task.yield() }
    #expect(sent.value.map(\.0) == [.resolvePermission(.init(askID: "a1", decision: .allowOnce))])
    #expect(sent.value.map(\.1) == [id])
  }
}
