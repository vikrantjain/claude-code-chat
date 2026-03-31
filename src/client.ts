import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const name = process.env.CLAUDE_CHAT_NAME || "agent-" + Math.random().toString(36).slice(2, 5);
const brokerUrl = process.env.CLAUDE_CHAT_BROKER || "ws://localhost:4000";

// MCP server
const mcp = new McpServer(
  { name: "claude-chat", version: "1.0.0" },
  {
    capabilities: { experimental: { "claude/channel": {} } },
    instructions:
      'Messages from other Claude Code instances arrive as <channel source="claude-chat" from="name">. ' +
      "To reply or send any message, you MUST use the mcp tool send_message (set 'to' for a specific recipient, omit to broadcast). " +
      "To see who is online, use the mcp tool list_participants. " +
      'Join/leave notifications arrive as <channel source="claude-chat" event="joined|left">.',
  }
);

// WebSocket (assigned after mcp.connect)
let ws: WebSocket;
let pendingList: ((names: string[]) => void) | null = null;

// Tools
mcp.registerTool("send_message", {
  description: "Send a message to other Claude Code instances. Omit 'to' to broadcast to all.",
  inputSchema: {
    text: z.string().describe("Message text"),
    to: z.string().optional().describe("Recipient name (optional, omit to broadcast)"),
  },
}, async ({ text, to }) => {
  ws.send(JSON.stringify({ type: "message", text, ...(to && { to }) }));
  return { content: [{ type: "text", text: to ? `sent to ${to}` : "broadcast sent" }] };
});

mcp.registerTool("list_participants", {
  description: "List all currently connected Claude Code instances.",
}, async () => {
  const names = await new Promise<string[]>((resolve, reject) => {
    pendingList = resolve;
    ws.send(JSON.stringify({ type: "list" }));
    setTimeout(() => {
      if (pendingList) {
        pendingList = null;
        reject(new Error("list_participants timed out"));
      }
    }, 5000);
  });
  return { content: [{ type: "text", text: names.join(", ") || "(no participants)" }] };
});

// Start MCP transport first, then connect to broker
const transport = new StdioServerTransport();
await mcp.connect(transport);

// Now connect to broker
ws = new WebSocket(brokerUrl);

ws.onopen = () => {
  ws.send(JSON.stringify({ type: "register", name }));
};

ws.onmessage = async (event) => {
  const msg = JSON.parse(event.data as string);

  if (msg.type === "registered") return;

  if (msg.type === "participants") {
    if (pendingList) {
      pendingList(msg.names);
      pendingList = null;
    }
    return;
  }

  if (msg.type === "message") {
    await mcp.server.notification({
      method: "notifications/claude/channel",
      params: {
        content: msg.text,
        meta: { from: msg.from, ...(msg.to && { to: msg.to }) },
      },
    });
    return;
  }

  if (msg.type === "joined" || msg.type === "left") {
    await mcp.server.notification({
      method: "notifications/claude/channel",
      params: {
        content: msg.name,
        meta: { event: msg.type },
      },
    });
    return;
  }

  if (msg.type === "error") {
    console.error("broker error:", msg.message);
  }
};

ws.onerror = () => {
  console.error("WebSocket error — is the broker running?");
  process.exit(1);
};

ws.onclose = () => {
  console.error("broker connection closed");
  process.exit(1);
};
