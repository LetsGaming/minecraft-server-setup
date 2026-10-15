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

test_a_failed_copy_leaves_the_scripts_and_restarts_the_server() {
  # S-019: a copy that fails (a full disk) after the server was stopped used
  # to leave an empty scripts folder and the server down.
  setup
  echo "# local edit" >> "$SCRIPTS/start.sh"
  chmod +x "$T/bin/"*   # copied shims lack the bit; without it PATH skips them
  touch "$SHIM_STATE/screen_running"
  cat > "$T/bin/cp" <<'SHIM'
#!/bin/bash
for a in "$@"; do [[ "$a" == *migrate-staging* ]] && { echo "cp: No space left on device" >&2; exit 1; }; done
exec /bin/cp "$@"
SHIM
  chmod +x "$T/bin/cp"
  migrate
  assert_nonzero "$RC" "the migration reports the failure"
  assert_contains "$OUT" "Undoing what it changed" "says it is undoing"
  assert_contains "$(cat "$SCRIPTS/start.sh")" "# local edit" "the scripts are the previous ones"
  assert_exists "$SCRIPTS/common/variables.txt" "with their variables.txt"
  assert_logged "systemctl stop inst.service" "the migration had stopped the server"
  assert_logged "systemctl start inst.service" "and starts it again"
  local leftovers
  leftovers="$(find "$ROOT/scripts" -maxdepth 1 -name 'inst.*' ! -name '*_backup_*' | head -n 3)"
  assert_eq "" "$leftovers" "no staging, preserve or old folder is left behind"
  teardown
}

# The prune engine's state under common/prune/: what a migration keeps and what it clears.
prune_state() {
  mkdir -p "$SCRIPTS/common/prune/cache/overworld" "$SCRIPTS/common/prune/tiles/overworld"
  echo '{"zones":[{"name":"base"}]}' > "$SCRIPTS/common/prune/settings.json"
  echo '{"plan":"p1","state":"applying"}' > "$SCRIPTS/common/prune/prune-apply.journal"
  echo '{}' > "$SCRIPTS/common/prune/p1.plan.json"
  echo 'meta' > "$SCRIPTS/common/prune/cache/overworld/r.0.0.meta"
  echo 'png' > "$SCRIPTS/common/prune/tiles/overworld/r.0.0.0123456789abcdef.png"
}

test_a_migration_keeps_prune_settings_and_journal_and_clears_plans_cache_and_tiles() {
  setup
  prune_state
  echo "# local edit" >> "$SCRIPTS/start.sh" # something to replace
  migrate
  assert_rc 0 "$RC" "migrate succeeds"
  assert_file_content "$SCRIPTS/common/prune/settings.json" '{"zones":[{"name":"base"}]}' "the saved settings and zones are kept"
  assert_file_content "$SCRIPTS/common/prune/prune-apply.journal" '{"plan":"p1","state":"applying"}' "the delete journal is kept"
  assert_missing "$SCRIPTS/common/prune/p1.plan.json" "plans are cleared"
  assert_missing "$SCRIPTS/common/prune/cache" "the scan cache is cleared"
  assert_missing "$SCRIPTS/common/prune/tiles" "the terrain tiles are cleared"
  assert_eq "700" "$(stat -c %a "$SCRIPTS/common/prune")" "the folder stays owner only"
  assert_contains "$OUT" "CLEAR   common/prune/  (3 plan, scan cache and terrain tile file(s)" "the clearing is one line"
  assert_not_contains "$OUT" "REMOVE  common/prune" "no line per cached file"
  teardown
}

test_prune_cache_files_alone_are_no_reason_to_migrate() {
  setup
  prune_state
  migrate
  assert_contains "$OUT" "Everything is already up to date" "nothing else changed, so nothing to do"
  assert_exists "$SCRIPTS/common/prune/tiles/overworld/r.0.0.0123456789abcdef.png" "and the tiles stay"
  teardown
}

test_a_migration_keeps_the_suites_own_state() {
  setup
  ( umask 077; mkdir -p "$SCRIPTS/.locks" "$SCRIPTS/common/migration-backups" )
  : > "$SCRIPTS/.locks/operation_inst.lock"
  echo "[Unit]" > "$SCRIPTS/common/migration-backups/inst.service.20261014-182144"
  echo "2026-10-14 unit_start_limits applied" > "$SCRIPTS/common/server-migrations.log"
  echo '{"seq":1,"phase":"start","status":"done"}' > "$SCRIPTS/common/upgrade-status.ndjson"
  echo "# local edit" >> "$SCRIPTS/start.sh" # something to replace
  migrate
  assert_rc 0 "$RC" "migrate succeeds"
  assert_exists "$SCRIPTS/.locks/operation_inst.lock" "the operation lock is kept"
  assert_eq "700" "$(stat -c %a "$SCRIPTS/.locks")" "the lock folder stays owner only"
  assert_file_content "$SCRIPTS/common/migration-backups/inst.service.20261014-182144" "[Unit]" "the replaced unit is kept"
  assert_eq "700" "$(stat -c %a "$SCRIPTS/common/migration-backups")" "and its folder stays owner only"
  assert_file_content "$SCRIPTS/common/server-migrations.log" "2026-10-14 unit_start_limits applied" "the migration record is kept"
  assert_file_content "$SCRIPTS/common/upgrade-status.ndjson" '{"seq":1,"phase":"start","status":"done"}' "the last job's status is kept"
  assert_not_contains "$OUT" "REMOVE  .locks" "none of it is reported as stale"
  assert_not_contains "$OUT" "REMOVE  common/" "none of it is reported as stale"
  teardown
}

test_the_suites_own_state_alone_is_no_reason_to_migrate() {
  setup
  mkdir -p "$SCRIPTS/.locks" "$SCRIPTS/common/migration-backups"
  : > "$SCRIPTS/.locks/operation_inst.lock"
  echo "x" > "$SCRIPTS/common/upgrade-status.ndjson"
  echo "x" > "$SCRIPTS/common/server-migrations.log"
  migrate
  assert_contains "$OUT" "Everything is already up to date" "nothing to do"
  teardown
}

run_tests
