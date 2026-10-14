// Preloaded with `node --require` so scripts under test get a canned axios.
// AXIOS_STUB_FILE points at a JSON map: url -> { status, json } or
// { status, bodyBase64, headers }. Every request is appended to
// AXIOS_STUB_LOG (one URL per line). No network is ever touched.
const Module = require("module");
const fs = require("fs");
const { Readable } = require("stream");

const realLoad = Module._load;

function table() {
  return JSON.parse(fs.readFileSync(process.env.AXIOS_STUB_FILE, "utf8"));
}

function lookup(url) {
  const entry = table()[url];
  if (process.env.AXIOS_STUB_LOG) fs.appendFileSync(process.env.AXIOS_STUB_LOG, url + "\n");
  if (!entry) {
    const err = new Error(`axios stub: no canned response for ${url}`);
    err.response = { status: 404, data: { description: "no canned response" } };
    throw err;
  }
  if (entry.status && entry.status >= 400) {
    const err = new Error(`Request failed with status code ${entry.status}`);
    err.response = { status: entry.status, data: entry.json ?? {} };
    throw err;
  }
  return entry;
}

function respond(entry, config) {
  if (config && config.responseType === "stream") {
    const body = Buffer.from(entry.bodyBase64 ?? "", "base64");
    return { status: 200, headers: entry.headers ?? {}, data: Readable.from([body]) };
  }
  return { status: entry.status ?? 200, headers: entry.headers ?? {}, data: entry.json };
}

function axios(config) {
  return Promise.resolve().then(() => respond(lookup(config.url), config));
}
// Like the real module, so scripts can set a default timeout on it.
axios.defaults = { timeout: 0 };
axios.get = (url, config) => Promise.resolve().then(() => respond(lookup(url), config));

Module._load = function (request, ...rest) {
  if (request === "axios") return axios;
  return realLoad.call(this, request, ...rest);
};
