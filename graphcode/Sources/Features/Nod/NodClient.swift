import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The chat pane's only line to a running Nod: records out of `events.jsonl`, commands into
/// `control.sock` (NodRuntime/PROTOCOL.md). A dependency so a reducer test, a preview and
/// a headless render can feed the pane a scripted log without a runtime.
struct NodClient: Sendable {
  /// Every record already in the log as the first element, then each batch appended after.
  /// Ends when the consuming task is cancelled.
  var events: @Sendable (_ stateDirectory: URL) -> AsyncStream<[NodEventRecord]>
  /// Throws when the runtime cannot be reached or answers `{"ok":false}`.
  var send: @Sendable (_ stateDirectory: URL, _ command: NodCommand) async throws -> Void
}

enum NodStateDirectory {
  /// `$NOD_STATE` — `<support dir>/nod/<node-uuid>/`, which the runtime is launched with.
  static func url(forNode id: UUID, supportDirectory: URL = SupportDirectory.url) -> URL {
    supportDirectory.appendingPathComponent("nod", isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
  }
}

/// Splits appended bytes into records, holding a torn final line back until the rest of
/// it arrives. Pure, so the tail's edge cases are testable without a file.
struct NodEventTail: Equatable {
  private(set) var offset: UInt64 = 0
  private var partial = Data()

  /// The file was replaced or truncated under the tail (a fresh run's log): start over.
  mutating func reset() {
    offset = 0
    partial = Data()
  }

  mutating func consume(_ data: Data) -> [NodEventRecord] {
    offset += UInt64(data.count)
    partial.append(data)
    guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
    let complete = partial[partial.startIndex...lastNewline]
    partial = Data(partial[partial.index(after: lastNewline)...])
    return NodProtocol.records(fromJSONLines: Data(complete))
  }
}

enum NodControlError: Error, Equatable, LocalizedError {
  case unreachable(String)
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .unreachable(let detail): return "Nod isn't running (\(detail))."
    case .rejected(let message): return message
    }
  }
}

/// One command, one connection: connect, write the line, read the one-line reply. Bounded
/// both ways so a wedged runtime fails the send instead of hanging the pane.
enum NodControlSocket {
  static let timeoutSeconds = 5

  static func send(_ command: NodCommand, to socketPath: String) throws {
    var line = try NodProtocol.makeEncoder().encode(command)
    line.append(UInt8(ascii: "\n"))

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NodControlError.unreachable("socket: \(errno)") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw NodControlError.unreachable("socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw NodControlError.unreachable("connect: \(errno)") }

    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == line.count else { throw NodControlError.unreachable("write: \(errno)") }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while !reply.contains(UInt8(ascii: "\n")) {
      let count = read(fd, &buffer, buffer.count)
      guard count > 0 else { break }
      reply.append(contentsOf: buffer[0..<count])
    }
    let firstLine = reply.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? Data()
    guard let answer = try? JSONDecoder().decode(Reply.self, from: firstLine) else {
      throw NodControlError.unreachable("no reply")
    }
    guard answer.ok else { throw NodControlError.rejected(answer.error ?? "Nod refused that.") }
  }

  private struct Reply: Decodable {
    var ok: Bool
    var error: String?
  }
}

extension NodClient: DependencyKey {
  static let pollInterval: Duration = .milliseconds(200)

  static let liveValue = NodClient(
    events: { directory in
      AsyncStream { continuation in
        let task = Task.detached(priority: .utility) {
          let url = directory.appendingPathComponent("events.jsonl")
          var tail = NodEventTail()
          var isFirst = true
          while !Task.isCancelled {
            let size =
              ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
              .uint64Value
            if let size, size < tail.offset { tail.reset() }
            if let size, size > tail.offset, let handle = try? FileHandle(forReadingFrom: url) {
              try? handle.seek(toOffset: tail.offset)
              let data = (try? handle.readToEnd()) ?? Data()
              try? handle.close()
              let records = tail.consume(data)
              if !records.isEmpty || isFirst { continuation.yield(records) }
            } else if isFirst {
              continuation.yield([])
            }
            isFirst = false
            try? await Task.sleep(for: pollInterval)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    },
    send: { directory, command in
      let path = directory.appendingPathComponent("control.sock").path
      try await Task.detached(priority: .userInitiated) {
        try NodControlSocket.send(command, to: path)
      }.value
    })

  static let testValue = NodClient(
    events: { _ in AsyncStream { $0.finish() } }, send: { _, _ in })

  /// A fixed log and a sink that accepts everything — for previews and headless renders.
  static func replaying(_ records: [NodEventRecord]) -> NodClient {
    NodClient(
      events: { _ in
        AsyncStream { continuation in
          continuation.yield(records)
        }
      },
      send: { _, _ in })
  }
}

extension DependencyValues {
  var nodClient: NodClient {
    get { self[NodClient.self] }
    set { self[NodClient.self] = newValue }
  }
}

/// The slice of Settings › Agents › Nod the chat reads and writes, through NodSetup's own
/// `NodSettings` methods so the pane and the settings editor never disagree.
struct NodSettingsClient: Sendable {
  var current: @Sendable () -> NodSettings
  /// "Always in <project>": the runtime keeps it for the session only; the shell allowlist
  /// is what makes it outlive the run.
  var addAllowlistPattern: @Sendable (String) async -> Void
  /// The composer's edit-policy chip, kept for every Nod loop after this one.
  var setEditPolicy: @Sendable (NodSettings.EditPolicy) async -> Void
  /// Sign in again, raise the spend cap: both live on Settings › Agents › Nod.
  var openNodSettings: @Sendable () async -> Void
}

extension NodSettingsClient: DependencyKey {
  static let liveValue = NodSettingsClient(
    current: { GraphcodeSettingsStore.load().nod },
    addAllowlistPattern: { pattern in
      await MainActor.run {
        _ = SettingsModel.shared.settings.nod.addAllowlistPattern(pattern)
      }
    },
    setEditPolicy: { policy in
      await MainActor.run { SettingsModel.shared.settings.nod.editsInWorktree = policy }
    },
    openNodSettings: {
      await MainActor.run { SettingsModel.shared.requestedPane = .agent(.nod) }
    })

  static let testValue = NodSettingsClient(
    current: { NodSettings() }, addAllowlistPattern: { _ in }, setEditPolicy: { _ in },
    openNodSettings: {})
}

extension DependencyValues {
  var nodSettings: NodSettingsClient {
    get { self[NodSettingsClient.self] }
    set { self[NodSettingsClient.self] = newValue }
  }
}
