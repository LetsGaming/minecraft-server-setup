// Writes a gzip-compressed ustar archive that holds only symlink entries, so
// tests can build archives that reference jars/ on hosts where creating real
// symlinks is not possible.
//
// Usage: node mk_symlink_archive.js <out> <name>=<target> [<name>=<target> ...]
const fs = require("fs");
const zlib = require("zlib");

function field(buf, offset, length, value) {
  buf.write(value, offset, length, "latin1");
}

function octal(value, width) {
  return value.toString(8).padStart(width - 1, "0") + "\0";
}

function symlinkHeader(name, target) {
  const header = Buffer.alloc(512, 0);
  field(header, 0, 100, name);
  field(header, 100, 8, octal(0o777, 8));
  field(header, 108, 8, octal(0, 8));
  field(header, 116, 8, octal(0, 8));
  field(header, 124, 12, octal(0, 12));
  field(header, 136, 12, octal(0, 12));
  header.fill(0x20, 148, 156);
  field(header, 156, 1, "2");
  field(header, 157, 100, target);
  field(header, 257, 6, "ustar\0");
  field(header, 263, 2, "00");
  let sum = 0;
  for (const byte of header) sum += byte;
  field(header, 148, 8, sum.toString(8).padStart(6, "0") + "\0 ");
  return header;
}

const [out, ...pairs] = process.argv.slice(2);
const blocks = pairs.map((pair) => {
  const i = pair.indexOf("=");
  return symlinkHeader(pair.slice(0, i), pair.slice(i + 1));
});
blocks.push(Buffer.alloc(1024, 0));
fs.writeFileSync(out, zlib.gzipSync(Buffer.concat(blocks)));
