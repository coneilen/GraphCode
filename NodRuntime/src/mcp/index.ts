export { daemonClient, socketPath, DaemonError, type GraphDaemon } from "./daemon";
export { classifyInbound, type InboundMail, type WireGraph } from "./graph";
export {
  createGraphcodeTools,
  sendDraft,
  serverName,
  type GraphcodeTool,
  type GraphcodeToolContext,
  type MailDraftEvent,
  type MessagePolicy,
  type ToolResult,
} from "./tools";
