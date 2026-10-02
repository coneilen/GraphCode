import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Speaks `control.sock`: one `NodCommand` per line out, one `{"ok":…}` line back.
///
/// One connection per command. The runtime answers each line in order, so a shared
/// connection would buy nothing but a reader that has to match replies to callers.
public enum NodControlClient {
  public enum Failure: Error, Equatable, Sendable {
    case unreachable
    case refused(String)
    case malformedReply
  }

  /// Bounds both the write and the reply. A runtime wedged mid-turn must not hold the
  /// daemon's delivery, which falls back to typing the message instead.
  static let timeout: TimeInterval = 2

  public static func send(_ command: NodCommand, toNodeID nodeID: UUID) async -> Result<
    Void, Failure
  > {
    await send(command, socketPath: NodRuntimeLocator.controlSocket(forNodeID: nodeID).path)
  }

  public static func send(_ command: NodCommand, socketPath: String) async -> Result<
    Void, Failure
  > {
    guard var line = try? NodProtocol.makeEncoder().encode(command) else {
      return .failure(.malformedReply)
    }
    line.append(UInt8(ascii: "\n"))
    let request = line
    return await Task.detached { exchange(request, socketPath: socketPath) }.value
  }

  static func parseReply(_ data: Data) -> Result<Void, Failure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let ok = object["ok"] as? Bool
    else { return .failure(.malformedReply) }
    return ok ? .success(()) : .failure(.refused(object["error"] as? String ?? ""))
  }

  #if canImport(Darwin) || canImport(Glibc)
    private static func exchange(_ request: Data, socketPath: String) -> Result<Void, Failure> {
      guard FileManager.default.fileExists(atPath: socketPath) else {
        return .failure(.unreachable)
      }
      #if canImport(Darwin)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      #else
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
      #endif
      guard descriptor >= 0 else { return .failure(.unreachable) }
      defer { close(descriptor) }
      var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
      let size = socklen_t(MemoryLayout<timeval>.size)
      setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, size)
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, size)
      #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      #endif

      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let capacity = MemoryLayout.size(ofValue: address.sun_path)
      guard socketPath.utf8.count < capacity else { return .failure(.unreachable) }
      #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      #endif
      withUnsafeMutablePointer(to: &address.sun_path) { field in
        field.withMemoryRebound(to: CChar.self, capacity: capacity) { pointer in
          _ = socketPath.withCString { strncpy(pointer, $0, capacity - 1) }
        }
      }
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else { return .failure(.unreachable) }

      #if canImport(Darwin)
        let flags: Int32 = 0
      #else
        let flags = Int32(MSG_NOSIGNAL)
      #endif
      var written = 0
      while written < request.count {
        let count = request.withUnsafeBytes { bytes in
          #if canImport(Darwin)
            Darwin.send(descriptor, bytes.baseAddress! + written, request.count - written, flags)
          #else
            Glibc.send(descriptor, bytes.baseAddress! + written, request.count - written, flags)
          #endif
        }
        guard count > 0 else { return .failure(.unreachable) }
        written += count
      }

      var reply = Data()
      var buffer = [UInt8](repeating: 0, count: 512)
      while !reply.contains(UInt8(ascii: "\n")) {
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(contentsOf: buffer[0..<count])
      }
      guard let line = reply.split(separator: UInt8(ascii: "\n")).first else {
        return .failure(.malformedReply)
      }
      return parseReply(Data(line))
    }
  #else
    private static func exchange(_ request: Data, socketPath: String) -> Result<Void, Failure> {
      .failure(.unreachable)
    }
  #endif
}
