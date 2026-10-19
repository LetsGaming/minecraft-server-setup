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
