// setup/common/properties.js: writing values into server.properties text.
const test = require("node:test");
const assert = require("node:assert/strict");
const { applyProperties, escapePropertyValue } = require("../../src/setup/common/properties.js");

test("$ sequences in a value are written as they are, not read as replacement patterns", () => {
  const text = applyProperties("level-name=old\nmotd=old\n", {
    "level-name": "a$$b$&x$1",
    motd: "cost: $`$'",
  });
  assert.match(text, /^level-name=a\$\$b\$&x\$1$/m);
  assert.match(text, /^motd=cost: \$`\$'$/m);
});

test("a missing key is appended and an existing one replaced in place", () => {
  const text = applyProperties("a=1\nb=2\n", { b: "9", c: "3" });
  assert.equal(text, "a=1\nb=9\n\nc=3");
});

test("newlines never reach the file", () => {
  assert.equal(escapePropertyValue("one\r\ntwo\nthree"), "onetwothree");
});

test("leading whitespace survives the loader, which would otherwise drop it", () => {
  assert.equal(escapePropertyValue("  hi"), "\\ \\ hi");
  assert.equal(escapePropertyValue("\thi"), "\\thi");
});

test("a trailing backslash cannot continue the line onto the next property", () => {
  assert.equal(escapePropertyValue("ends\\"), "ends\\\\");
  assert.equal(escapePropertyValue("even\\\\"), "even\\\\");
  const text = applyProperties("motd=x\nonline-mode=true\n", { motd: "line\\" });
  assert.deepEqual(text.split("\n"), ["motd=line\\\\", "online-mode=true", ""]);
});

test("escapes the author wrote on purpose are passed through", () => {
  assert.equal(escapePropertyValue("a\\nb \\u00a7cred"), "a\\nb \\u00a7cred");
});

test("regex characters in a key are matched literally", () => {
  const text = applyProperties("rcon.port=1\nrconXport=2\n", { "rcon.port": "25575" });
  assert.equal(text, "rcon.port=25575\nrconXport=2\n");
});

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const SETUP = path.join(__dirname, "..", "..", "src", "setup");

function runSetServerProperties(serverVars, existingProps) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "serverprops-"));
  try {
    for (const rel of ["common/loadVariables.js", "common/properties.js", "variables/set_server_properties.js"]) {
      const dest = path.join(root, "src", "setup", rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(path.join(SETUP, rel), dest);
    }
    const vars = {
      INSTANCE_NAME: "s",
      TARGET_DIR_NAME: "mc",
      BACKUPS: {
        COMPRESSION_LEVEL: 3, MAX_STORAGE_GB: 10, MAX_HOURLY_BACKUPS: 1,
        MAX_DAILY_BACKUPS: 1, MAX_WEEKLY_BACKUPS: 1, MAX_MONTHLY_BACKUPS: 1,
      },
      JAVA: {
        SERVER: {
          MAX_PLAYERS: 10, MOTD: "m", WHITELIST: false, SEED: "", DIFFICULTY: "normal",
          PVP: false, FLIGHT_ENABLED: true, ALLOW_CRACKED: false, ...serverVars,
        },
        JAVA_ARGS_CONFIG: {
          minMemory: "1M", maxMemory: "1M", metaspaceLimit: "64M", garbageCollector: "zgc",
          zgc: { uncommitDelay: "1h", uncommitDelayOnIdle: "30m", heapReservePercent: 5, concurrentGCThreads: 2, softMaxHeapSize: "1M" },
        },
      },
    };
    fs.writeFileSync(path.join(root, "variables.json"), JSON.stringify(vars));
    const instance = path.join(root, "mc", "instances", "s");
    fs.mkdirSync(instance, { recursive: true });
    if (existingProps !== undefined) fs.writeFileSync(path.join(instance, "server.properties"), existingProps);
    const run = spawnSync(process.execPath, [path.join(root, "src", "setup", "variables", "set_server_properties.js")], {
      env: { ...process.env, MAIN_DIR: root },
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    return fs.readFileSync(path.join(instance, "server.properties"), "utf8");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("server-port is written from JAVA.SERVER.PORT, replacing an existing line", () => {
  const text = runSetServerProperties({ PORT: 25566 }, "server-port=25565\nmotd=x\n");
  assert.match(text, /^server-port=25566$/m);
  assert.equal(text.match(/^server-port=/gm).length, 1);
});

test("server-port defaults to 25565 and is appended when the file lacks it", () => {
  const text = runSetServerProperties({}, "motd=x\n");
  assert.match(text, /^server-port=25565$/m);
});
