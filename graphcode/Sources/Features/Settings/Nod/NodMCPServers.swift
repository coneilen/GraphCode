import Foundation
import GraphcodeKit

/// One row of Settings › Agents › Nod › MCP servers.
struct NodMCPServer: Equatable, Identifiable {
  enum Source: Equatable {
    /// graphcode's own server: siblings, edges, the mailroom. Always on.
    case builtIn
    /// A project's `.mcp.json`; the associated value is the project's name.
    case project(String)
  }

  var name: String
  var source: Source
  /// A remote (http/sse) server that sends no Authorization header of its own, so it
  /// will want an OAuth sign-in before Nod can call it.
  var needsSignIn: Bool

  var id: String { name }

  static let graphcode = NodMCPServer(name: "graphcode", source: .builtIn, needsSignIn: false)

  /// The built-in server, then every server the known projects' `.mcp.json` files
  /// declare, first project wins on a name clash. Settings has no project of its own,
  /// so "known" is the recent-projects list, the same rule the Templates section uses.
  static func load(projects: [ProjectRef]) -> [NodMCPServer] {
    var servers = [graphcode]
    for project in projects where !project.path.contains("://") {
      let file = URL(fileURLWithPath: project.path).appending(path: ".mcp.json")
      guard let data = try? Data(contentsOf: file) else { continue }
      for server in parse(data, projectName: project.name)
      where !servers.contains(where: { $0.name == server.name }) {
        servers.append(server)
      }
    }
    return servers
  }

  /// Reads `{"mcpServers": {name: {type?, command?, url?, headers?}}}`, the shape Claude
  /// Code and the Agent SDK share. Anything unreadable yields no rows rather than an
  /// error: a broken `.mcp.json` is the CLIs' problem to report too.
  static func parse(_ data: Data, projectName: String) -> [NodMCPServer] {
    guard
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let declared = root["mcpServers"] as? [String: Any]
    else { return [] }
    return declared.keys.sorted().compactMap { name in
      guard name != graphcode.name, let config = declared[name] as? [String: Any] else {
        return nil
      }
      let type = (config["type"] as? String)?.lowercased()
      let isRemote = type == "http" || type == "sse" || (type == nil && config["url"] != nil)
      let headers = (config["headers"] as? [String: Any]) ?? [:]
      let authorises = headers.keys.contains { $0.lowercased() == "authorization" }
      return NodMCPServer(
        name: name, source: .project(projectName), needsSignIn: isRemote && !authorises)
    }
  }
}
