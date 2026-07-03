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
  // BUG-02: reject negative/oversized lengths. Without this a corrupt or
  // hostile packet with a negative length passes `buf.length < 4 + length`
  // (e.g. 4 + -1 = 3) and yields a silent empty/garbage body. A valid RCON
  // packet is >= 10 bytes and in practice never exceeds 4 KB.
  if (length < 10 || length > 4096) return null;
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

    const COMMAND_ID = 2;
    const SENTINEL_ID = 3; // distinct id used to detect the end of a multi-packet reply
    let collected = ""; // accumulates the body of all COMMAND_ID response packets

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
            // Send the real command, immediately followed by an empty sentinel
            // command. The server processes packets in order, so once we see the
            // sentinel's echo we know every fragment of the real command's
            // (possibly multi-packet) response has arrived. This is the standard
            // way to read long replies like /list or /whitelist list without
            // truncation.
            client.write(encodePacket(COMMAND_ID, PACKET_TYPE.COMMAND, command));
            client.write(encodePacket(SENTINEL_ID, PACKET_TYPE.COMMAND, ""));
          }
        } else if (packet.id === COMMAND_ID) {
          collected += packet.body;
        } else if (packet.id === SENTINEL_ID) {
          // Reached the end marker — the full response has been collected.
          cleanup();
          resolve(collected);
          return;
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
//   Preferred:  RCON_PASSWORD=secret node rcon.js <host> <port> <command...>
//   Legacy:     node rcon.js <host> <port> <password> <command...>
// Passing the password via the environment keeps it out of the process
// argument list, which is world-readable via `ps` / /proc/<pid>/cmdline.
if (require.main === module) {
  const argv = process.argv.slice(2);
  const envPassword = process.env.RCON_PASSWORD;

  let host, port, password, cmdParts;
  if (envPassword !== undefined && envPassword !== "") {
    [host, port, ...cmdParts] = argv;
    password = envPassword;
  } else {
    [host, port, password, ...cmdParts] = argv;
  }
  const command = cmdParts.join(" ");

  if (!host || !port || !password || !command) {
    console.error(
      "Usage: RCON_PASSWORD=secret node rcon.js <host> <port> <command>\n" +
        "   or: node rcon.js <host> <port> <password> <command>",
    );
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
