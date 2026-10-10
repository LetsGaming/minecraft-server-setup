// Scratch instances for the update/*.js tests. Nothing here touches a real
// server: the scripts are copied into a temp tree whose variables.txt points
// at temp directories, and axios is replaced by tests/js/axiosStub.cjs.
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const UPDATE_SRC = path.resolve(__dirname, "..", "..", "src", "scripts", "update");
const STUB = path.join(__dirname, "axiosStub.cjs").split(path.sep).join("/");

function makeInstance() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mcsetup-jstest-"));
  const scripts = path.join(root, "scripts");
  const server = path.join(root, "server");
  fs.mkdirSync(path.join(scripts, "common"), { recursive: true });
  fs.mkdirSync(path.join(server, "mods"), { recursive: true });
  fs.cpSync(UPDATE_SRC, path.join(scripts, "update"), {
    recursive: true,
    filter: (src) => !src.includes("node_modules"),
  });
  fs.writeFileSync(
    path.join(scripts, "common", "variables.txt"),
    `USER="tester"\nINSTANCE_NAME="inst"\nSERVER_PATH="${server}"\n`,
  );
  const stubFile = path.join(root, "stub.json");
  const stubLog = path.join(root, "stub.log");
  fs.writeFileSync(stubFile, "{}");
  fs.writeFileSync(stubLog, "");
  return {
    root,
    scripts,
    server,
    mods: path.join(server, "mods"),
    manifestPath: path.join(scripts, "common", "downloaded_versions.json"),
    stubFile,
    stubLog,
    writeManifest(obj) {
      fs.writeFileSync(this.manifestPath, JSON.stringify(obj, null, 2));
    },
    readManifest() {
      return JSON.parse(fs.readFileSync(this.manifestPath, "utf8"));
    },
    stub(table) {
      fs.writeFileSync(this.stubFile, JSON.stringify(table));
    },
    requests() {
      return fs.readFileSync(this.stubLog, "utf8").split("\n").filter(Boolean);
    },
    run(script, args = [], env = {}) {
      const res = spawnSync(
        process.execPath,
        [path.join(scripts, "update", script), ...args],
        {
          cwd: scripts,
          encoding: "utf8",
          env: {
            ...process.env,
            NODE_OPTIONS: `--require ${STUB}`,
            AXIOS_STUB_FILE: stubFile,
            AXIOS_STUB_LOG: stubLog,
            ...env,
          },
        },
      );
      return { code: res.status, stdout: res.stdout, stderr: res.stderr };
    },
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
}

function b64(text) {
  return Buffer.from(text).toString("base64");
}

function sha(algo, text) {
  return crypto.createHash(algo).update(text).digest("hex");
}

function lastJson(stdout) {
  const lines = stdout.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
}

module.exports = { makeInstance, b64, sha, lastJson };
