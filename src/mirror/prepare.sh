#!/bin/bash
# Prepares a NEW instance as the creative side of a mirror: creative game mode,
# a seed that matches the survival server, the two mods the design needs (pinned
# versions, hash-checked), FabricPlots without its own game-mode switching,
# Dimensional Inventories pools that keep the plots and the mirror apart, and RCON
# so the pull can talk to the server. It changes files only; the server is not
# started, and a server that is running or a world that already exists is refused
# (a seed cannot be changed on an existing world).
#
# Usage: prepare.sh --scripts-dir DIR [--seed SEED] [--force] [--dry-run]
#   --force    go ahead although a world already exists (the seed stays as it is)
#   --dry-run  say what would change, change nothing
#
# Env: MIRROR_NODE (node binary), MIRROR_PREPARE_MODS=skip (tests)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$HERE/lib/config.sh" ]]; then LIB="$HERE/lib"; else LIB="$HERE/src/mirror/lib"; fi
# shellcheck source=lib/config.sh
source "$LIB/config.sh"

SCRIPTS_DIR="" SEED="" FORCE=false DRY_RUN=false
while (($#)); do
  case "$1" in
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "[prepare] ERROR: $*" >&2; exit 1; }
say() { echo "[prepare] $*"; }
NODE="${MIRROR_NODE:-node}"

[[ -n "$SCRIPTS_DIR" && -f "$SCRIPTS_DIR/common/variables.txt" ]] || die "pass --scripts-dir with a deployed scripts folder"
VARS="$SCRIPTS_DIR/common/variables.txt"
var() { mirror_config_value "$VARS" "$1"; }
INSTANCE_NAME="$(var INSTANCE_NAME)"
SERVER_PATH="$(var SERVER_PATH)"
PROPS="$SERVER_PATH/server.properties"
[[ -d "$SERVER_PATH" && -f "$PROPS" ]] || die "no server.properties in $SERVER_PATH; set the instance up first"

if [[ "$(var MIRROR_ROLE)" != target ]]; then
  die "this instance is not set up as a mirror target; run mirror.sh setup target first"
fi

# prop_set <key> <value>: the line in server.properties, replaced or appended.
prop_set() {
  local key="$1" value="$2" tmp
  if $DRY_RUN; then say "server.properties: $key=$value"; return 0; fi
  tmp="$(mktemp "$PROPS.XXXXXX")"
  awk -v k="$key" -v v="$value" 'BEGIN { done = 0 } $0 ~ "^" k "=" { if (!done) { print k "=" v; done = 1 }; next } { print } END { if (!done) print k "=" v }' "$PROPS" > "$tmp"
  chmod --reference="$PROPS" "$tmp" 2> /dev/null || true
  mv -f -- "$tmp" "$PROPS"
}

# var_set <KEY> <value>: a KEY="value" line in variables.txt, replaced or appended.
var_set() {
  local key="$1" value="$2" tmp
  if $DRY_RUN; then say "variables.txt: $key=\"$value\""; return 0; fi
  tmp="$(mktemp "$VARS.XXXXXX")"
  awk -v k="$key" -v v="$value" 'BEGIN { done = 0 } $0 ~ "^" k "=" { if (!done) { print k "=\"" v "\""; done = 1 }; next } { print } END { if (!done) print k "=\"" v "\"" }' "$VARS" > "$tmp"
  chmod --reference="$VARS" "$tmp" 2> /dev/null || true
  mv -f -- "$tmp" "$VARS"
}

# --- guards -----------------------------------------------------------------

if systemctl is-active --quiet "$INSTANCE_NAME.service" 2> /dev/null && ! $DRY_RUN; then
  die "$INSTANCE_NAME is running; stop it first (prepare edits server.properties and the mods)"
fi
WORLD="$SERVER_PATH/$(sed -n 's/^level-name=//p' "$PROPS" | tail -n 1 | tr -d '\r')"
[[ "$WORLD" != "$SERVER_PATH/" ]] || WORLD="$SERVER_PATH/world"
NEW_WORLD=true
if [[ -f "$WORLD/level.dat" ]]; then
  NEW_WORLD=false
  $FORCE || die "a world already exists at $WORLD. prepare is for a new instance: a seed cannot be changed on an existing world. Use --force to prepare the rest anyway."
  say "a world exists; the seed and the world are left as they are"
fi

# --- seed -------------------------------------------------------------------

if [[ -n "$SEED" ]]; then
  [[ "$SEED" =~ ^-?[0-9]+$ ]] || die "--seed must be a number (the survival server's /seed)"
  $NEW_WORLD && prop_set level-seed "$SEED"
else
  current="$(sed -n 's/^level-seed=//p' "$PROPS" | tail -n 1 | tr -d '\r')"
  [[ -n "$current" ]] || die "no seed: pass --seed with the survival server's /seed (a creative mirror needs the same seed)"
  say "using the seed already in server.properties: $current"
fi

# --- game mode, compression, RCON ---------------------------------------------

prop_set gamemode creative
# Dimensional Inventories owns the game mode per pool; forcing it on join would fight it.
prop_set force-gamemode false
prop_set region-file-compression deflate
if [[ "$(var USE_RCON)" != true || -z "$(var RCON_PASSWORD)" || "$(var RCON_PASSWORD)" == none ]]; then
  pw="$(od -An -N16 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')"
  [[ ${#pw} -eq 32 ]] || die "could not generate an RCON password"
  var_set USE_RCON true
  var_set RCON_PASSWORD "$pw"
  prop_set rcon.password "$pw"
else
  prop_set rcon.password "$(var RCON_PASSWORD)"
fi
prop_set enable-rcon true
rcon_port="$(var RCON_PORT)"
prop_set rcon.port "${rcon_port:-25575}"

# --- mods ---------------------------------------------------------------------

MC_VERSION="$("$NODE" -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).gameVersion||"")}catch(e){console.log("")}' "$SCRIPTS_DIR/common/downloaded_versions.json" 2> /dev/null || true)"
if [[ "${MIRROR_PREPARE_MODS:-}" == skip ]]; then
  say "mods: skipped"
else
  [[ -n "$MC_VERSION" ]] || die "could not read the Minecraft version from downloaded_versions.json"
  mods_args=(--mods-dir "$SERVER_PATH/mods" --mc-version "$MC_VERSION" --pins "$HERE/pins.json")
  [[ -f "$HERE/pins.json" ]] || mods_args[5]="$HERE/src/mirror/pins.json"
  $DRY_RUN && mods_args+=(--dry-run)
  mods_js="$HERE/prepare_mods.js"
  [[ -f "$mods_js" ]] || mods_js="$HERE/src/mirror/prepare_mods.js"
  "$NODE" "$mods_js" "${mods_args[@]}"
fi

# On a server that has never started, a worldgen-changing mod the suite installed by
# default (C2ME) is turned off: it makes chunks generated later on this server
# differ from the survival server's more than anything else tested.
if $NEW_WORLD && [[ -d "$SERVER_PATH/mods" ]] && compgen -G "$SERVER_PATH/mods/*[Cc]2me*.jar" > /dev/null; then
  if $DRY_RUN; then
    say "would disable C2ME (new world; it widens the difference from the survival server)"
  elif [[ -f "$SCRIPTS_DIR/update/toggle-mod.js" ]] && (cd "$SCRIPTS_DIR/update" && "$NODE" toggle-mod.js c2me-fabric --disable > /dev/null 2>&1); then
    say "C2ME is disabled on this new server (mirror.sh doctor explains why); enable it again with toggle-mod.js if you prefer speed"
  else
    say "NOTE: C2ME is installed here; remove it from mods/ if you want generated chunks to match the survival server"
  fi
fi

# --- FabricPlots and Dimensional Inventories ----------------------------------

CONFIG_DIR="$SERVER_PATH/config"
if $DRY_RUN; then
  say "config/fabricplots.properties: manage-gamemode=false"
else
  mkdir -p "$CONFIG_DIR"
  plots_cfg="$CONFIG_DIR/fabricplots.properties"
  if [[ -f "$plots_cfg" ]]; then
    awk 'BEGIN { d = 0 } /^manage-gamemode=/ { if (!d) print "manage-gamemode=false"; d = 1; next } { print } END { if (!d) print "manage-gamemode=false" }' "$plots_cfg" > "$plots_cfg.new" && mv -f -- "$plots_cfg.new" "$plots_cfg"
  else
    echo "manage-gamemode=false" > "$plots_cfg"
  fi
fi

POOLS="$WORLD/dimensional-inventories/v2/config/main/dimension-pools.json"
if [[ -f "$POOLS" ]]; then
  say "Dimensional Inventories pools exist already; left as they are"
elif $DRY_RUN; then
  say "would write the pools default (nether, end), mirror (overworld), plots (fabricplots:plots), all creative"
else
  mkdir -p "$(dirname "$POOLS")"
  cat > "$POOLS" <<'JSON'
{
  "version": 1,
  "data": {
    "dimensionPools": [
      {
        "dimensions": ["minecraft:the_end", "minecraft:the_nether"],
        "id": "default",
        "displayName": "default",
        "gameMode": "CREATIVE",
        "progressAdvancements": true,
        "incrementStatistics": true
      },
      {
        "dimensions": ["minecraft:overworld"],
        "id": "mirror",
        "displayName": "mirror",
        "gameMode": "CREATIVE",
        "progressAdvancements": true,
        "incrementStatistics": true
      },
      {
        "dimensions": ["fabricplots:plots"],
        "id": "plots",
        "displayName": "plots",
        "gameMode": "CREATIVE",
        "progressAdvancements": true,
        "incrementStatistics": true
      }
    ]
  }
}
JSON
  say "Dimensional Inventories pools written: the plots, the mirrored overworld and the Nether with the End (one pool) each keep their own inventory, all creative"
fi

say "done. On a 26.3 server white-list defaults to true: add players or set it on purpose."
say "Start the server once, then let the first pull run (mirror.sh pull), or wait for the timer."
