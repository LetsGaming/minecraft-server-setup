#!/usr/bin/env node
// Minimal Minecraft RCON client
// Usage: node rcon.js <host> <port> <password> <command>

const net = require("net");

const PACKET_TYPE = {
  AUTH: 3,
  AUTH_RESPONSE: 2,
  COMMAND: 2,
  COMMAND_RESPONSE: 0,
};

function encodePacket(id, type, body) {
  const bodyBuf = Buffer.from(body, "utf-8");
  // length(4) + id(4) + type(4) + body + null(1) + null(1)
  const length = 4 + 4 + bodyBuf.length + 1 + 1;
  const buf = Buffer.alloc(4 + length);
  buf.writeInt32LE(length, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  bodyBuf.copy(buf, 12);
  buf.writeInt8(0, 12 + bodyBuf.length);
  buf.writeInt8(0, 13 + bodyBuf.length);
  return buf;
}

function decodePacket(buf) {
  if (buf.length < 14) return null;
  const length = buf.readInt32LE(0);
  if (buf.length < 4 + length) return null;
  return {
    length,
    id: buf.readInt32LE(4),
    type: buf.readInt32LE(8),
    body: buf.toString("utf-8", 12, 4 + length - 2),
    totalSize: 4 + length,
  };
}

function rconCommand(host, port, password, command, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const client = new net.Socket();
    let responseBuf = Buffer.alloc(0);
    let authenticated = false;
    let timer = null;

    const cleanup = () => {
      if (timer) clearTimeout(timer);
      client.destroy();
    };

    timer = setTimeout(() => {
      cleanup();
      reject(new Error("RCON timeout"));
    }, timeoutMs);

    client.connect(port, host, () => {
      client.write(encodePacket(1, PACKET_TYPE.AUTH, password));
    });

    client.on("data", (data) => {
      responseBuf = Buffer.concat([responseBuf, data]);

      while (true) {
        const packet = decodePacket(responseBuf);
        if (!packet) break;
        responseBuf = responseBuf.slice(packet.totalSize);

        if (!authenticated) {
          if (packet.id === -1) {
            cleanup();
            reject(new Error("RCON authentication failed"));
            return;
          }
          if (packet.id === 1 && packet.type === PACKET_TYPE.AUTH_RESPONSE) {
            authenticated = true;
            client.write(encodePacket(2, PACKET_TYPE.COMMAND, command));
          }
        } else {
          if (packet.id === 2) {
            cleanup();
            resolve(packet.body);
            return;
          }
        }
      }
    });

    client.on("error", (err) => {
      cleanup();
      reject(new Error(`RCON connection error: ${err.message}`));
    });

    client.on("close", () => {
      if (timer) clearTimeout(timer);
    });
  });
}

// CLI usage
if (require.main === module) {
  const [host, port, password, ...cmdParts] = process.argv.slice(2);
  const command = cmdParts.join(" ");

  if (!host || !port || !password || !command) {
    console.error("Usage: node rcon.js <host> <port> <password> <command>");
    process.exit(1);
  }

  rconCommand(host, parseInt(port), password, command)
    .then((response) => {
      if (response.trim()) console.log(response.trim());
      process.exit(0);
    })
    .catch((err) => {
      console.error(err.message);
      process.exit(1);
    });
}

module.exports = { rconCommand };
