// resolve_default_version.js: the newest Minecraft release Fabric and the default mods all support.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const SCRIPT = path.join(__dirname, "..", "..", "src", "setup", "download", "resolve_default_version.js");
const STUB = path.join(__dirname, "axiosStub.cjs");
const { parseSlugs, readGroupSlugs, resolveDefaultVersion } = require(SCRIPT);

const MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
const FABRIC_URL = "https://meta.fabricmc.net/v2/versions/game";
const modUrl = (slug) => `https://api.modrinth.com/v2/project/${slug}/version`;

const manifest = (ids) => ({
  versions: [
    { id: "26.4-snapshot-1", type: "snapshot" },
    ...ids.map((id) => ({ id, type: "release" })),
    { id: "1.0", type: "release" },
  ],
});
const fabricGames = (ids) => ids.map((version) => ({ version, stable: true }));
const build = (...games) => [
  { game_versions: games, loaders: ["fabric"], version_type: "release", date_published: "2026-01-01T00:00:00Z" },
];

/** deps for resolveDefaultVersion: `mods` maps slug -> the game versions it has a fabric build for. */
function deps({ releases, fabric, mods }) {
  const table = {
    [FABRIC_URL]: { data: fabricGames(fabric) },
    ...Object.fromEntries(Object.entries(mods).map(([slug, games]) => [modUrl(slug), { data: build(...games) }])),
  };
  return {
    fetchManifest: async () => manifest(releases),
    get: async (url) => {
      if (!table[url]) throw new Error(`unexpected request ${url}`);
      return table[url];
    },
  };
}

test("latest_when_all_mods_support_it", async () => {
  const result = await resolveDefaultVersion({
    slugs: ["a", "b"],
    deps: deps({ releases: ["26.3", "26.2", "26.1"], fabric: ["26.3", "26.2", "26.1"], mods: { a: ["26.3"], b: ["26.3", "26.2"] } }),
  });
  assert.deepEqual(result, { minecraft: "26.3", notices: [], dropped: [] });
});

test("falls_back_to_older_version_when_a_mod_lacks_a_build", async () => {
  const result = await resolveDefaultVersion({
    slugs: ["a", "b"],
    deps: deps({ releases: ["26.3", "26.2", "26.1"], fabric: ["26.3", "26.2", "26.1"], mods: { a: ["26.3", "26.2"], b: ["26.2", "26.1"] } }),
  });
  assert.equal(result.minecraft, "26.2");
  assert.deepEqual(result.dropped, []);
  assert.equal(result.notices.length, 1);
  assert.equal(result.notices[0].severity, "adjusted");
  assert.match(result.notices[0].text, /26\.3/);
  assert.match(result.notices[0].text, /mod b\b/);
  assert.match(result.notices[0].text, /26\.2/);
});

test("drops_mods_when_no_version_in_range_works", async () => {
  const result = await resolveDefaultVersion({
    slugs: ["a", "b", "c"],
    deps: deps({
      releases: ["26.3", "26.2", "26.1"],
      fabric: ["26.3", "26.2", "26.1"],
      mods: { a: ["26.3"], b: ["26.2", "26.1"], c: ["26.2"] },
    }),
  });
  assert.equal(result.minecraft, "26.2");
  assert.deepEqual(result.dropped, ["a"]);
  assert.match(result.notices[0].text, /\ba\b/);
});

test("a tie on the number of supported mods goes to the newest version", async () => {
  const result = await resolveDefaultVersion({
    slugs: ["a", "b"],
    deps: deps({ releases: ["26.3", "26.2"], fabric: ["26.3", "26.2"], mods: { a: ["26.3"], b: ["26.2"] } }),
  });
  assert.equal(result.minecraft, "26.3");
  assert.deepEqual(result.dropped, ["b"]);
});

test("a candidate without a Fabric loader is skipped", async () => {
  const result = await resolveDefaultVersion({
    slugs: ["a"],
    deps: deps({ releases: ["26.3", "26.2"], fabric: ["26.2"], mods: { a: ["26.3", "26.2"] } }),
  });
  assert.equal(result.minecraft, "26.2");
  assert.match(result.notices[0].text, /26\.3 was skipped because Fabric/);
});

test("only the newest `lookback` releases are candidates", async () => {
  await assert.rejects(
    resolveDefaultVersion({
      slugs: ["a"],
      lookback: 1,
      deps: deps({ releases: ["26.3", "26.2"], fabric: ["26.2"], mods: { a: ["26.2"] } }),
    }),
    /Fabric has no stable loader/,
  );
});

test("a slug Modrinth does not know counts as having no build", async () => {
  const d = deps({ releases: ["26.3"], fabric: ["26.3"], mods: { a: ["26.3"] } });
  const get = d.get;
  d.get = async (url) => {
    if (url === modUrl("ghost")) throw Object.assign(new Error("404"), { response: { status: 404 } });
    return get(url);
  };
  const result = await resolveDefaultVersion({ slugs: ["a", "ghost"], deps: d });
  assert.deepEqual(result.dropped, ["ghost"]);
});

test("crlf_and_comment_slug_files_are_read", () => {
  assert.deepEqual(parseSlugs("lithium\r\n# note\r\n\r\n  clumps  \r\n#x\r\nkrypton"), ["lithium", "clumps", "krypton"]);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "resolve-slugs-"));
  try {
    fs.writeFileSync(path.join(dir, "performance_mods.txt"), "a\r\n# c\r\nb");
    fs.writeFileSync(path.join(dir, "utility_mods.txt"), "b\nc\n");
    assert.deepEqual(readGroupSlugs(["performance", "utility"], dir), ["a", "b", "c"]);
    assert.throws(() => readGroupSlugs(["nope"], dir), /Unknown mod group/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function runCli(table, args = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "resolve-cli-"));
  try {
    const file = path.join(dir, "stub.json");
    fs.writeFileSync(file, JSON.stringify(table));
    const res = spawnSync(process.execPath, [SCRIPT, ...args], {
      encoding: "utf8",
      env: { ...process.env, NODE_OPTIONS: `--require ${STUB.split(path.sep).join("/")}`, AXIOS_STUB_FILE: file },
    });
    return { code: res.status, stdout: res.stdout, stderr: res.stderr };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function cliTable({ releases, fabric, games }) {
  const table = {
    [MANIFEST_URL]: { json: manifest(releases) },
    [FABRIC_URL]: { json: fabricGames(fabric) },
  };
  for (const slug of readGroupSlugs(["performance", "utility"])) table[modUrl(slug)] = { json: build(...games) };
  return table;
}

test("the CLI prints exactly one JSON object on stdout", () => {
  const r = runCli(cliTable({ releases: ["26.3", "26.2", "26.1"], fabric: ["26.3"], games: ["26.3"] }));
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(r.stdout), { minecraft: "26.3", notices: [], dropped: [] });
  assert.equal(r.stdout.trim().split("\n").length, 1);
});

test("no_fabric_for_any_candidate_exits_1", () => {
  const r = runCli(cliTable({ releases: ["26.3", "26.2", "26.1"], fabric: ["25.9"], games: ["26.3"] }));
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "");
  assert.match(r.stderr, /Fabric has no stable loader/);
});

test("network_failure_exits_1", () => {
  const r = runCli({ [MANIFEST_URL]: { status: 503 } });
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "");
  assert.equal(r.stderr.trim().split("\n").length, 1);
  assert.match(r.stderr, /^resolve_default_version: /);
});

test("a bad --lookback exits 1", () => {
  const r = runCli({}, ["--lookback", "0"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /--lookback/);
});

test("a request timeout is a one-line error, not a no-build result", async () => {
  const d = deps({ releases: ["26.3"], fabric: ["26.3"], mods: { a: ["26.3"] } });
  d.get = async () => {
    throw Object.assign(new Error("timeout of 15000ms exceeded"), { code: "ECONNABORTED" });
  };
  await assert.rejects(resolveDefaultVersion({ slugs: ["a"], deps: d }), (err) => {
    assert.match(err.message, /timed out/);
    assert.equal(err.message.includes("\n"), false);
    return true;
  });
});

test("--version limits the candidates to that version", async () => {
  const d = deps({ releases: ["26.3", "26.2"], fabric: ["26.3", "26.2"], mods: { a: ["26.3", "26.2"] } });
  const result = await resolveDefaultVersion({ slugs: ["a"], version: "26.2", deps: d });
  assert.deepEqual(result, { minecraft: "26.2", notices: [], dropped: [] });
});

test("--version drops mods without a build and says so", async () => {
  const d = deps({ releases: ["26.3"], fabric: ["26.3", "26.2"], mods: { a: ["26.3", "26.2"], b: ["26.3"] } });
  const result = await resolveDefaultVersion({ slugs: ["a", "b"], version: "26.2", deps: d });
  assert.equal(result.minecraft, "26.2");
  assert.deepEqual(result.dropped, ["b"]);
  assert.equal(result.notices.length, 1);
  assert.match(result.notices[0].text, /\bb\b/);
});

test("--version without a Fabric loader fails", async () => {
  const d = deps({ releases: ["26.3"], fabric: ["26.3"], mods: { a: ["26.3"] } });
  await assert.rejects(resolveDefaultVersion({ slugs: ["a"], version: "1.2.3", deps: d }), /no stable loader for Minecraft 1\.2\.3/);
});

test("the CLI accepts --version", () => {
  const table = cliTable({ releases: ["26.3"], fabric: ["26.3", "26.2"], games: ["26.3", "26.2"] });
  const r = runCli(table, ["--version", "26.2"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).minecraft, "26.2");
});
