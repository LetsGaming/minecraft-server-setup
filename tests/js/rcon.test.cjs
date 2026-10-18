// common/rcon.js against a fake RCON server.
const test = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");
const { rconCommand } = require("../../src/scripts/common/rcon.js");

function pkt(id, type, body) {
  const b = Buffer.from(body, "utf8");
  const buf = Buffer.alloc(14 + b.length);
  buf.writeInt32LE(10 + b.length, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  b.copy(buf, 12);
  return buf;
}

/** A server that authenticates, then does `onCommand(sock)` for the first command. */
async function fakeServer(onCommand) {
  const server = net.createServer((sock) => {
    let seen = 0;
    sock.on("error", () => {});
    sock.on("data", (d) => {
      seen += 1;
      if (seen === 1) sock.write(pkt(1, 2, ""));
      else if (seen === 2) onCommand(sock);
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { port: server.address().port, close: () => new Promise((r) => server.close(r)) };
}

test("a server that hangs up without answering is a failure, not an empty success (S-010)", async () => {
  const srv = await fakeServer((sock) => sock.destroy());
  try {
    await assert.rejects(rconCommand("127.0.0.1", srv.port, "pw", "save-off", 2000), /closed before/);
  } finally {
    await srv.close();
  }
});

test("a full 4096-byte reply is read", async () => {
  const body = "y".repeat(4096);
  const srv = await fakeServer((sock) => {
    sock.write(pkt(2, 0, body));
    sock.write(pkt(3, 0, ""));
  });
  try {
    assert.equal(await rconCommand("127.0.0.1", srv.port, "pw", "list", 2000), body);
  } finally {
    await srv.close();
  }
});

test("a stream out of step fails at once instead of timing out", async () => {
  const srv = await fakeServer((sock) => {
    const bad = Buffer.alloc(20);
    bad.writeInt32LE(-5, 0);
    sock.write(bad);
  });
  try {
    await assert.rejects(rconCommand("127.0.0.1", srv.port, "pw", "list", 5000), /framing error/);
  } finally {
    await srv.close();
  }
});

const { execFile } = require("node:child_process");
const path = require("node:path");

function runCli(args, env) {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [path.join(__dirname, "../../src/scripts/common/rcon.js"), ...args],
      { env: { ...process.env, ...env } },
      (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr }),
    );
  });
}

test("the CLI --timeout-ms option bounds a command the server never answers", async () => {
  const srv = await fakeServer(() => {});
  try {
    const started = Date.now();
    const res = await runCli(["--timeout-ms=300", "127.0.0.1", String(srv.port), "save-all flush"], { RCON_PASSWORD: "pw" });
    assert.equal(res.code, 1);
    assert.match(res.stderr, /RCON timeout/);
    assert.ok(Date.now() - started < 4000, "gave up well before the 5 s default");
  } finally {
    await srv.close();
  }
});

test("the CLI still reads a long reply when given a timeout", async () => {
  const srv = await fakeServer((sock) => {
    sock.write(pkt(2, 0, "Saved the game"));
    sock.write(pkt(3, 0, ""));
  });
  try {
    const res = await runCli(["--timeout-ms=5000", "127.0.0.1", String(srv.port), "save-all", "flush"], { RCON_PASSWORD: "pw" });
    assert.equal(res.code, 0);
    assert.equal(res.stdout.trim(), "Saved the game");
  } finally {
    await srv.close();
  }
});
