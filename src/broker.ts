import type { ServerWebSocket } from "bun";

const port = Number(process.env.PORT || 4000);
const clients = new Map<ServerWebSocket, string>();

function broadcast(msg: object, exclude?: ServerWebSocket) {
  const data = JSON.stringify(msg);
  for (const [sock] of clients) {
    if (sock !== exclude) sock.send(data);
  }
}

Bun.serve({
  port: port,
  hostname: "0.0.0.0",
  fetch(req, server) {
    server.upgrade(req);
    return undefined;
  },
  websocket: {
    message(ws, raw) {
      const msg = JSON.parse(raw as string);

      if (msg.type === "register") {
        const name = msg.name || "agent-" + Math.random().toString(36).slice(2, 5);
        if ([...clients.values()].includes(name)) {
          ws.send(JSON.stringify({ type: "error", message: "name already taken" }));
          return;
        }
        clients.set(ws, name);
        console.log(`+ ${name} connected (${clients.size} online)`);
        ws.send(JSON.stringify({ type: "registered", name }));
        broadcast({ type: "joined", name }, ws);
        return;
      }

      const from = clients.get(ws);
      if (!from) return;

      if (msg.type === "list") {
        ws.send(JSON.stringify({ type: "participants", names: [...clients.values()] }));
        return;
      }

      if (msg.type === "message") {
        const outgoing = { type: "message", from, text: msg.text, ...(msg.to && { to: msg.to }) };
        if (msg.to) {
          for (const [sock, name] of clients) {
            if (name === msg.to) {
              sock.send(JSON.stringify(outgoing));
              return;
            }
          }
          ws.send(JSON.stringify({ type: "error", message: `unknown recipient: ${msg.to}` }));
        } else {
          broadcast(outgoing, ws);
        }
      }
    },
    close(ws) {
      const name = clients.get(ws);
      if (name) {
        clients.delete(ws);
        console.log(`- ${name} disconnected (${clients.size} online)`);
        broadcast({ type: "left", name });
      }
    },
  },
});

console.log(`broker listening on ws://0.0.0.0:${port}`);

process.on("SIGINT", () => {
  console.log("\nbroker shutting down");
  process.exit(0);
});
process.on("SIGTERM", () => {
  console.log("\nbroker shutting down");
  process.exit(0);
});
