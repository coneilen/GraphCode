/// What a loop's pane shows: a terminal running a CLI, or Nod's chat. The new-loop agent
/// menu groups backends by this, because it is the difference you notice when the loop
/// opens.
public enum AgentSurface: String, Codable, CaseIterable, Sendable {
  case chat
  case terminal
}
