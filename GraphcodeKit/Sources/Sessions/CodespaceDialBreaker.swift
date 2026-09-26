import Foundation

/// The daemon's side of `CodespaceDialSchedule`: one outage clock per codespace, shared
/// by every read and ensure that would otherwise each rediscover the outage on its own
/// clock. Plain ssh hosts are never gated — their dials multiplex over one connection and
/// cost no API calls.
///
/// A paused codespace resumes when a human asks: the terminal pane's "press Enter to
/// reconnect" touches `reconnectMarker(for:)`, and a marker newer than the outage clears
/// it. A file rather than a daemon command because the pane is a shell loop in the app's
/// process, and a `stat` spends nothing.
public actor CodespaceDialBreaker {
  static let shared = CodespaceDialBreaker()

  private let schedule: CodespaceDialSchedule
  private let markerDirectory: URL
  private var downSince: [String: Date] = [:]

  init(
    schedule: CodespaceDialSchedule = .standard,
    markerDirectory: URL = CodespaceDialBreaker.defaultMarkerDirectory
  ) {
    self.schedule = schedule
    self.markerDirectory = markerDirectory
  }

  public static var defaultMarkerDirectory: URL {
    SupportDirectory.url.appendingPathComponent("codespace-dials", isDirectory: true)
  }

  public static func reconnectMarker(
    for location: RemoteProjectLocation, in directory: URL = defaultMarkerDirectory
  ) -> URL {
    directory.appendingPathComponent("\(location.host).reconnect")
  }

  func permits(_ location: RemoteProjectLocation, now: Date = Date()) -> Bool {
    guard location.isCodespace, let since = downSince[location.host] else { return true }
    switch schedule.verdict(secondsDown: now.timeIntervalSince(since)) {
    case .dial: return true
    case .hold: return false
    case .paused:
      guard reconnectRequested(for: location, after: since) else { return false }
      downSince.removeValue(forKey: location.host)
      return true
    }
  }

  func record(_ location: RemoteProjectLocation, reached: Bool, now: Date = Date()) {
    guard location.isCodespace else { return }
    if reached {
      downSince.removeValue(forKey: location.host)
    } else if downSince[location.host] == nil {
      downSince[location.host] = now
    }
  }

  private func reconnectRequested(for location: RemoteProjectLocation, after since: Date) -> Bool {
    let marker = Self.reconnectMarker(for: location, in: markerDirectory)
    guard
      let touched = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[
        .modificationDate] as? Date
    else { return false }
    return touched > since
  }
}
