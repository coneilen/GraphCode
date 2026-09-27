import Dependencies
import GraphcodeKit

/// Asks a codespace's dialers to retry now (`CodespaceDialBreaker.requestReconnect`), as a
/// dependency so a reducer test can see the request without touching the support
/// directory.
struct CodespaceReconnectClient: Sendable {
  var request: @Sendable (RemoteProjectLocation) -> Void
}

extension CodespaceReconnectClient: DependencyKey {
  static let liveValue = CodespaceReconnectClient(request: {
    CodespaceDialBreaker.requestReconnect(for: $0)
  })

  static let testValue = CodespaceReconnectClient(request: { _ in })
}

extension DependencyValues {
  var codespaceReconnect: CodespaceReconnectClient {
    get { self[CodespaceReconnectClient.self] }
    set { self[CodespaceReconnectClient.self] = newValue }
  }
}
