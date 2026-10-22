#!/bin/bash
# Measures zstd ratio and speed per level on this server's own data, so the
# choice of BACKUP_HOURLY_LEVEL and BACKUP_ZSTD_THREADS rests on numbers.
# Uses zstd's built-in benchmark on a tar of the staging mirror (or of the
# server directory when no mirror exists yet). Nothing is written to the
# backups folders; the sample tar lives in a temporary file.
#
# Usage: bench_levels.sh [--levels 1-19] [--threads N] [--sample-mb N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../common/load_variables.sh"
BK_COMPONENT=bench
source "$SCRIPT_DIR/../lib/bk_common.sh"

LEVELS="1-19"
THREADS=""
SAMPLE_MB=512
while [[ $# -gt 0 ]]; do
  case "$1" in
    --levels) LEVELS="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --sample-mb) SAMPLE_MB="$2"; shift 2 ;;
    --help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) bk_log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
done
[[ "$LEVELS" =~ ^([0-9]+)-([0-9]+)$ ]] || { bk_log ERROR "--levels wants a range such as 1-19"; exit 1; }
FROM="${BASH_REMATCH[1]}"; TO="${BASH_REMATCH[2]}"
bk_load_config || exit 1
[[ -n "$THREADS" ]] || THREADS="$(bk_zstd_threads)"
command -v zstd >/dev/null || { bk_log ERROR "zstd is not installed"; exit 1; }

SRC="$BACKUPS_PATH/.stage/mirror"
[[ -d "$SRC" ]] || SRC="$SERVER_PATH"
bk_log INFO "Sampling up to ${SAMPLE_MB} MiB of $SRC (region files first, as they dominate the size)"

TMP="$(mktemp "${TMPDIR:-/tmp}/bench.XXXXXX.tar")"
trap 'rm -f -- "$TMP"' EXIT

# Region files are the bulk of a world and the hardest to compress; a sample
# led by them is representative of the real archive.
(
  cd "$SRC"
  { find . -path '*/region/*.mca' -type f 2>/dev/null; find . -type f ! -path '*/region/*' ! -name '*.jar' 2>/dev/null; } |
    head -n 5000 | tar -cf - --no-recursion -T - 2>/dev/null
) | head -c $((SAMPLE_MB * 1024 * 1024)) > "$TMP"
SIZE="$(stat -c %s -- "$TMP")"
bk_log INFO "Sample: $(bk_human_bytes "$SIZE"); running zstd -b$FROM -e$TO -T$THREADS (current hourly level: $BACKUP_HOURLY_LEVEL, archive level: $BACKUP_ARCHIVE_LEVEL)"
echo
bk_nice zstd -q -b"$FROM" -e"$TO" -T"$THREADS" "$TMP"
echo
bk_log INFO "Columns: level, input, output, ratio, compression MB/s, decompression MB/s."
bk_log INFO "Set BACKUP_HOURLY_LEVEL to the lowest level whose ratio you accept; archives can stay higher."
