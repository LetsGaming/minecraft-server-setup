#!/bin/bash
# Builds on fixture.sh for the mirror tests: a source and a target instance, each
# a copy of the fixture's scripts with its own server folder, world and mirror
# settings, plus the stand-ins the jobs call to stop and start the server.
# Needs the real rsync (MC_TEST_REAL_TOOLS=1); the tests skip without it.

MIRROR_SRC="$(cd "$SHELL_TEST_DIR/../../src/mirror" && pwd)"
EXPORT_SH="$MIRROR_SRC/bin/export.sh"
PULL_SH="$MIRROR_SRC/bin/pull.sh"

have_real_rsync() { real_tools; }

# mirror_world <server-dir> <label> [regions]: a 26.x world with chunk folders.
mirror_world() {
  local dir="$1" label="$2" regions="${3:-4}" w i
  w="$dir/world/dimensions/minecraft/overworld"
  rm -rf "$dir/world"
  mkdir -p "$w/region" "$w/entities" "$w/poi" "$w/data/minecraft" "$dir/logs" "$dir/mods"
  for ((i = 0; i < regions; i++)); do echo "$label-region-$i" > "$w/region/r.$i.0.mca"; done
  echo "$label-entities" > "$w/entities/r.0.0.mca"
  echo "$label-poi" > "$w/poi/r.0.0.mca"
  echo "$label-border" > "$w/data/minecraft/world_border.dat"
  echo "$label" > "$dir/world/level.dat"
  printf 'level-name=world\nlevel-seed=424242\n' > "$dir/server.properties"
  echo "[00:00:00] [ServerMain/INFO]: Starting minecraft server version 26.3" > "$dir/logs/latest.log"
  touch "$dir/mods/c2me-fabric-1.0.jar" "$dir/mods/lithium-1.0.jar"
}

# mirror_set <instance-dir> KEY value: one more line in that instance's variables.txt.
mirror_set() { echo "$2=\"$3\"" >> "$1/scripts/common/variables.txt"; }

# mk_instance <name> <role>: <T>/<name>/{scripts,server,backups,state} configured
# for the mirror. The scripts are a copy of the fixture's.
mk_instance() {
  local n="$1" role="$2" d="$T/$1"
  mkdir -p "$d/server" "$d/backups" "$d/locks"
  cp -r "$T/scripts" "$d/scripts"
  sed -i -e "s|^SERVER_PATH=.*|SERVER_PATH=\"$d/server\"|" -e "s|^BACKUPS_PATH=.*|BACKUPS_PATH=\"$d/backups\"|" -e "s|^INSTANCE_NAME=.*|INSTANCE_NAME=\"$n\"|" "$d/scripts/common/variables.txt"
  mirror_set "$d" MIRROR_ENABLED true
  mirror_set "$d" MIRROR_ROLE "$role"
  mirror_set "$d" MIRROR_STATE "$d/mirror"
  mirror_world "$d/server" "$n"
  # the server "stops" and "starts" by flipping the screen shim's state; a start
  # writes the line the pull waits for
  cat > "$d/stop.sh" <<SH
#!/bin/bash
echo stop >> "$d/calls"
rm -f "$SHIM_STATE/screen_running"
SH
  cat > "$d/start.sh" <<SH
#!/bin/bash
echo start >> "$d/calls"
touch "$SHIM_STATE/screen_running"
echo "[00:00:09] [Server thread/INFO]: Done (3.210s)! For help, type \"help\"" >> "$d/server/logs/latest.log"
SH
  mirror_set "$d" MIRROR_STOP_CMD "bash $d/stop.sh"
  mirror_set "$d" MIRROR_START_CMD "bash $d/start.sh"
  mirror_set "$d" MIRROR_WARN_SECONDS 0
  mirror_set "$d" MIRROR_STOP_GRACE 0
}

# run_job <instance> <script> [args...] ; sets OUT and RC. INSTANCE_NAME comes from
# the instance's own variables.txt, the way a unit starts the job.
run_job() {
  local n="$1" script="$2"
  shift 2
  OUT="$(cd "$T/$n/scripts" && INSTANCE_LOCK_DIR="$T/$n/locks" bash "$script" --scripts-dir "$T/$n/scripts" "$@" 2>&1 < /dev/null)"
  RC=$?
}

snapshot_dir() { find "$T/$1/mirror/export/snapshots" -mindepth 1 -maxdepth 1 -type d -name '2*' 2> /dev/null | sort | tail -n 1; }
