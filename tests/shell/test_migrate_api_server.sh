#!/bin/bash
# migrate.sh and the API wrapper: an installed wrapper is brought to the release
# pinned in api-server-release.json, downloaded from a local stand-in for GitHub
# releases. The suite is copied to a scratch folder so the pin can be rewritten;
# systemctl, sudo and screen are shims.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh
source lib/fixture.sh

REPO_ROOT="$(cd ../.. && pwd)"

# make_release <version> <dist text>: a tarball shaped like the wrapper's release.
make_release() {
  local version="$1" text="$2" src
  src="$(mktemp -d "$T/rel.XXXXXX")"
  mkdir -p "$src/mc-api-server-$version/dist"
  local top="$src/mc-api-server-$version"
  printf '{"name":"mc-api-server","version":"%s","type":"module"}' "$version" > "$top/package.json"
  printf '{"name":"mc-api-server","version":"%s","lockfileVersion":3,"requires":true,"packages":{"":{"name":"mc-api-server","version":"%s"}}}' \
    "$version" "$version" > "$top/package-lock.json"
  echo 'import "./dist/index.js";' > "$top/index.js"
  echo "$text" > "$top/dist/index.js"
  mkdir -p "$T/releases/v$version"
  "$REAL_TAR" -czf "$T/releases/v$version/mc-api-server-$version.tar.gz" -C "$src" "mc-api-server-$version"
  rm -rf "$src"
}

# pin <version> [sha]: rewrite the scratch suite's pin (sha defaults to the built tarball's).
pin() {
  local version="$1" sha="${2:-}"
  if [[ -z "$sha" ]]; then
    sha="$(sha256sum "$T/releases/v$version/mc-api-server-$version.tar.gz" | cut -d' ' -f1)"
  fi
  printf '{"repository":"LetsGaming/minecraft-server-api","version":"%s","sha256":"%s"}\n' "$version" "$sha" \
    > "$SUITE/api-server-release.json"
}

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/mcsetup-migrate-api.XXXXXX")"
  SUITE="$T/suite"; ROOT="$T/root"; SCRIPTS="$ROOT/scripts/inst"; API="$ROOT/services/api-server"
  mkdir -p "$SUITE" "$SCRIPTS" "$ROOT/instances/inst" "$T/bin" "$T/state" "$T/releases"
  cp "$REPO_ROOT/migrate.sh" "$SUITE/"
  "$REAL_TAR" -C "$REPO_ROOT" --exclude=node_modules --exclude=src/scripts/api-server -cf - src | "$REAL_TAR" -C "$SUITE" -xf -
  cp -r "$SUITE/src/scripts/." "$SCRIPTS/"
  cat > "$SCRIPTS/common/variables.txt" <<VARS
USER="tester"
INSTANCE_NAME="inst"
SERVER_PATH="$ROOT/instances/inst"
BACKUPS_PATH="$T/backups"
USE_RCON="false"
RCON_HOST="localhost"
RCON_PORT="25575"
RCON_PASSWORD=""
WEBHOOK_URL=""
WEBHOOK_EVENTS=""
RESTART_ENABLED="false"
RESTART_INTERVAL_HOURS="12"
RESTART_SKIP_IF_EMPTY="true"
RESTART_WARN_SECONDS="30"
API_SERVER_ENABLED="true"
API_SERVER_PORT="3000"
API_SERVER_KEY=""
VARS
  for s in sudo systemctl screen; do cp "shims/$s" "$T/bin/$s"; done
  export SHIM_LOG="$T/shim.log" SHIM_STATE="$T/state" INSTANCE_NAME=inst
  : > "$SHIM_LOG"

  # A local stand-in for github.com/<repo>/releases/download, logging each request.
  node -e '
    const http = require("http"), fs = require("fs"), path = require("path");
    const [root, portFile, log] = process.argv.slice(1);
    http.createServer((req, res) => {
      fs.appendFileSync(log, req.url + "\n");
      const file = path.join(root, path.normalize(req.url));
      if (file.startsWith(root) && fs.existsSync(file)) { res.writeHead(200); res.end(fs.readFileSync(file)); }
      else { res.writeHead(404); res.end(); }
    }).listen(0, "127.0.0.1", function () { fs.writeFileSync(portFile, String(this.address().port)); });
  ' "$T/releases" "$T/port" "$T/requests.log" &
  SERVER_PID=$!
  for _ in $(seq 50); do [[ -s "$T/port" ]] && break; command sleep 0.1; done
  MC_API_SERVER_RELEASE_BASE="http://127.0.0.1:$(cat "$T/port")"
  export MC_API_SERVER_RELEASE_BASE
  : > "$T/requests.log"
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null
  rm -rf "$T"
}

# An install from the submodule days: the wrapper's files, no .release.json.
unmanaged_install() {
  mkdir -p "$API/dist" "$API/logs"
  echo '{"name":"mc-api-server","version":"4.0.0"}' > "$API/package.json"
  echo 'import "./dist/index.js";' > "$API/index.js"
  echo "// old" > "$API/dist/index.js"
  echo "// stale" > "$API/dist/removed.js"
  echo '{"apiKey":"keep-me"}' > "$API/api-server-config.json"
  echo "old log" > "$API/logs/api-server.log"
}

migrate() {
  OUT="$(PATH="$T/bin:$PATH" bash "$SUITE/migrate.sh" "$SCRIPTS" --y --no-server-migrations "$@" 2>&1 < /dev/null)"
  RC=$?
}

test_an_unmanaged_install_is_replaced_by_the_pinned_release() {
  setup
  unmanaged_install
  make_release 4.1.0 "// new"
  pin 4.1.0
  migrate
  assert_rc 0 "$RC" "migrate succeeds"
  assert_contains "$OUT" "copy from before releases, 4.0.0 → release 4.1.0" "the preview names the old copy and the release"
  assert_file_content "$API/dist/index.js" "// new" "the release's code is installed"
  assert_missing "$API/dist/removed.js" "files the release does not ship are gone"
  assert_file_content "$API/api-server-config.json" '{"apiKey":"keep-me"}' "the config is kept"
  assert_file_content "$API/logs/api-server.log" "old log" "the logs are kept"
  assert_exists "$API/.release.json" "the release is recorded"
  assert_contains "$(cat "$T/requests.log")" "/v4.1.0/mc-api-server-4.1.0.tar.gz" "the pinned asset was downloaded"
  assert_contains "$OUT" "No systemd unit root-api-server.service" "a missing unit is reported, not restarted"
  assert_missing "$SCRIPTS/api-server" "nothing of the wrapper lands in the instance's scripts"

  migrate
  assert_contains "$OUT" "Everything is already up to date" "a second run has nothing to do"
  teardown
}

test_a_failed_download_leaves_the_running_wrapper_alone() {
  setup
  unmanaged_install
  pin 9.9.9 "$(printf '0%.0s' $(seq 64))"
  migrate
  assert_contains "$OUT" "previous install is unchanged" "the failure is reported"
  assert_contains "$OUT" "still runs 4.0.0" "the summary says what still runs"
  assert_file_content "$API/dist/index.js" "// old" "the old code is still in place"
  assert_missing "$API/.release.json" "no release is recorded"
  assert_not_logged "systemctl restart root-api-server.service" "the wrapper is not restarted"
  teardown
}

test_a_host_without_the_wrapper_downloads_nothing() {
  setup
  make_release 4.1.0 "// new"
  pin 4.1.0
  migrate
  assert_rc 0 "$RC" "migrate succeeds"
  assert_contains "$OUT" "Everything is already up to date" "nothing to do"
  assert_missing "$API" "no wrapper is installed"
  assert_eq "" "$(cat "$T/requests.log")" "nothing was downloaded"
  teardown
}

test_dry_run_changes_nothing() {
  setup
  unmanaged_install
  make_release 4.1.0 "// new"
  pin 4.1.0
  migrate --dry-run
  assert_contains "$OUT" "release 4.1.0" "the preview names the release"
  assert_file_content "$API/dist/index.js" "// old" "the install is untouched"
  assert_eq "" "$(cat "$T/requests.log")" "nothing was downloaded"
  teardown
}

run_tests
