# Setup Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command after `git clone` leaves a non-IT user with a running, backed-up Fabric server, through three routes (Default, Guided, Power-user), without slowing down admins.

**Architecture:** `main.sh` gains a route selector and a prerequisite stage that runs before any `node` call. Default and Guided are Bash: a manifest-driven whiptail wizard (`src/wizard/`) over shared detector, validator and correction libraries that writes `variables.json` with `jq`; the existing install pipeline, `loadVariables.js` validation and rollback run unchanged afterwards. Node keeps Modrinth/Mojang lookups (one new small CLI). A Bash script patches three Xaero config keys.

**Tech Stack:** Bash 4.3+, whiptail, jq (1.6/1.7 common subset), Node 18+ (existing), the existing `tests/shell` harness and `node --test`.

**Spec:** `docs/superpowers/specs/2026-10-21-setup-onboarding-design.md` (read it first; section numbers below refer to it). Research: `docs/research/setup-onboarding-ux.md`, `docs/research/node-to-bash-candidates.md`.

## Global Constraints

- Branch `feat/setup-onboarding`; work lands as waves of commits on it; **one PR at the end**; nothing is committed to `main`.
- Commits: Conventional Commits without scope, `type: lowercase imperative summary` (types feat, fix, refactor, chore, docs, test, perf). **No mention of Claude, Anthropic or AI, and no `Co-Authored-By` or `Claude-Session` trailers**, in commits or the PR.
- Never use em dashes anywhere (code, comments, docs, commits). English only.
- Code comments: default none; only non-obvious constraints; never narrate history or tasks.
- Debian/Ubuntu with systemd, cron, apt; Bash 4.3+ only (no `mapfile -d`, no `inherit_errexit`); no Docker; no GUI beyond whiptail.
- jq: only features common to 1.6 and 1.7 (`--arg`, `--argjson`, `--rawfile`, `//`, `setpath`, `-e`); keep seeds as strings; generated config is strict JSON.
- New Bash passes the existing ShellCheck workflow (severity warning, `.shellcheckrc`).
- Existing behaviour that must not change: the admin flags (`--check`, `--dry-run`, `--verbose`, `--no-start`, `--no-service`, `--no-backup`, `--agree-eula`, `--api-server`, `--vanilla`, `--y`), `variables.json` format, rollback on failure, 251 shell and 295 Node tests stay green.
- Test cadence: write each task's tests first, then implement; **run tests once at the end of each wave**, not per task. Shell tests: `bash tests/shell/run.sh test_x.sh ...`. Node: `node --test tests/js/x.test.cjs`.
- Secrets never appear on a command line, in logs or on screen.

## Review Focus

1. Whiptail unusable mid-wizard (terminal too small, exit 255, `TERM=dumb`): the run falls back to the Default route with a notice and never leaves a half-written `variables.json` (Task 7, Task 11).
2. Container or VM where the cgroup memory limit is below `MemAvailable`, or total usable RAM below 1.5 GB: safe heap chosen, red warning shown, install not blocked (Task 2, Task 9).
3. Port 25565 held by a non-Minecraft process, or by an IPv6-only listener, or taken between detection and start: next free port chosen and shown (Task 2, Task 9).
4. Ctrl-C during the wizard or a failed install: `variables.json` is either complete or absent while the wizard runs, and survives a rolled-back install (Task 8, Task 12).
5. Re-run on a machine where instance `server`, its directory or its systemd unit already exists: new free name, nothing existing touched (Task 2, Task 10).
6. No colour support (`NO_COLOR`, piped output, dumb terminal): warnings still distinct through `WARNING:` / `ADJUSTED:` prefixes (Task 1).

## File Structure

| Path | Responsibility |
|---|---|
| `src/common/ui.sh` (new) | colour detection, notice blocks, TTY checks |
| `src/common/corrections.sh` (new) | registry of automatic corrections and their rendering |
| `src/common/detect.sh` (new) | machine detectors (RAM, CPU, disk, ports, IP, OS, existing instances) |
| `src/common/prereqs.sh` (new) | prerequisite list, Node policy, `ensure_prerequisites` |
| `src/setup/download/download_packages.sh` | becomes a thin caller of `prereqs.sh` |
| `src/wizard/validators.sh` (new) | named reusable checks |
| `src/wizard/whiptail.sh` (new) | whiptail widget wrappers and fallbacks |
| `src/wizard/manifest.sh` (new) | the step data |
| `src/wizard/engine.sh` (new) | runs the manifest, Back/Cancel, answers map |
| `src/wizard/config_writer.sh` (new) | answers to `variables.json` via jq |
| `src/wizard/safety.sh` (new) | heap, port, name rules producing corrections |
| `src/wizard/route.sh` (new) | route selection, Default and Guided drivers, flag handoff |
| `src/wizard/summary.sh` (new) | summary screen, EULA step, final screen with networking notice |
| `src/setup/download/resolve_default_version.js` (new) | newest Minecraft version supported by Fabric and the default mod groups |
| `src/scripts/misc/xaero_config.sh` (new) | `apply` and `check` for the three Xaero keys |
| `main.sh`, `src/common/setup.sh`, `src/common/flags.sh` | stage order, new flags, early-read fixes |
| `src/scripts/misc/doctor.sh` | Xaero drift check |
| `tests/shell/test_*.sh` (new), `tests/shell/shims/{whiptail,ss,ip}` (new) | tests |

## Wave 0: Branch and docs

### Task 0: Branch and baseline docs

**Files:** Create branch; add `docs/research/*.md`, `docs/superpowers/specs/2026-10-21-setup-onboarding-design.md`, this plan.

- [ ] **Step 1:** `git switch -c feat/setup-onboarding` from `main`.
- [ ] **Step 2:** Commit the research, spec and plan files: `git commit -m "docs: add onboarding research, design and plan"`.

## Wave 1: Foundations (shared libraries)

### Task 1: UI and corrections libraries

**Files:** Create `src/common/ui.sh`, `src/common/corrections.sh`; Test `tests/shell/test_ui.sh`.

**Interfaces:**
- Produces `ui_color_enabled` (rc 0 when stdout is a TTY, `TERM` is not `dumb`, `NO_COLOR` unset); `ui_notice <adjusted|warning|error|info> <message>` (prints a block; `adjusted` yellow with prefix `ADJUSTED:`, `warning` red with `WARNING:`, `error` red with `ERROR:`; prefix always present, colour only when enabled); `ui_is_interactive` (rc 0 when stdin and stdout are TTYs).
- Produces `correction_add <severity:adjusted|warning> <subject> <asked> <chosen> <why>`, `corrections_count`, `corrections_render` (one block per correction, same prefix rules), `corrections_reset`.

- [ ] **Step 1: tests** in `test_ui.sh`: `test_notice_has_prefix_without_color` (NO_COLOR=1, output contains `ADJUSTED:` and no `\033`), `test_notice_uses_color_on_tty` (skip when no pty; otherwise contains `\033[`), `test_corrections_collect_and_render` (two adds, `corrections_count` is 2, render contains both subjects and the asked/chosen values), `test_corrections_reset`.
- [ ] **Step 2:** Implement both files (functions only, no top-level side effects, `set -e` safe).
- [ ] **Step 3: Commit:** `feat: add ui and corrections libraries`.

### Task 2: Detector library

**Files:** Create `src/common/detect.sh`; Test `tests/shell/test_detect.sh`; Create shims `tests/shell/shims/ss`, `tests/shell/shims/ip`.

**Interfaces (all print to stdout, rc 0 unless stated):**
- `detect_mem_available_mb` prints an integer: the lower of `MemAvailable` and the cgroup limit (`memory.max`, ignored when `max` or absent). Paths overridable by `MC_SETUP_MEMINFO` and `MC_SETUP_CGROUP_MEMMAX`.
- `detect_cpu_count`; `detect_disk_free_gb <path>` (walks up to the nearest existing parent; `df -Pk`); `detect_os_id` / `detect_os_version_id` (from `/etc/os-release`, overridable by `MC_SETUP_OS_RELEASE`).
- `detect_port_free <port>` rc 0 when nothing listens on TCP `<port>` (uses `ss -ltnH`, matches IPv4 and IPv6 listeners); `detect_next_free_port <start>` prints the first free port at or above `<start>`.
- `detect_local_ip` prints the source address of `ip route get 1.1.1.1`, empty when none.
- `detect_instance_exists <name> <target_dir_name>` rc 0 when `$HOME/<target>/instances/<name>`, `scripts/<name>`, or `/etc/systemd/system/<name>.service` (dir overridable by `SYSTEMD_UNIT_DIR`) exists; `detect_free_instance_name <base> <target_dir_name>` prints `base`, else `base-2`, `base-3`, ...

- [ ] **Step 1: tests** (shims on PATH via env `SS_SHIM_LISTEN="25565 [::]:25566"`, `IP_SHIM_SRC=192.168.1.20`): `test_mem_uses_lower_of_meminfo_and_cgroup` (meminfo 8000 MB available, cgroup 2048 MB gives 2048), `test_mem_ignores_cgroup_max`, `test_port_free_detects_ipv4_and_ipv6_listeners` (25565 busy, 25566 busy via `[::]`, 25567 free), `test_next_free_port_skips_busy` (25565 and 25566 busy gives 25567), `test_local_ip_from_route`, `test_instance_exists_by_dir_scripts_and_unit` (each of the three alone), `test_free_instance_name_sequence` (`server`, `server-2`, `server-3`), `test_disk_free_walks_up_to_existing_parent`.
- [ ] **Step 2:** Implement `detect.sh`; write the two shims (record calls in `$SHIM_LOG`).
- [ ] **Step 3: Commit:** `feat: add machine detection library`.

**Wave 1 verification:** `bash tests/shell/run.sh test_ui.sh test_detect.sh test_assert_harness.sh` all pass.

## Wave 2: Bootstrap and route plumbing (spec section 5, BC-001)

### Task 3: Prerequisite stage and Node policy

**Files:** Create `src/common/prereqs.sh`; Modify `src/setup/download/download_packages.sh`; Test `tests/shell/test_prereqs.sh`; Modify `tests/shell/test_setup_flags.sh` (tool-list assertions).

**Interfaces:**
- `PREREQ_COMMANDS`: associative array `command -> apt package` for `curl screen unzip cron jq rsync zstd setfacl(acl)` plus `node(nodejs) npm`; `whiptail` is added by `prereqs_missing guided` only.
- `prereqs_missing <route>` prints the apt packages not yet satisfied (route is `default|guided|power`).
- `node_major` prints the installed major or nothing; `distro_node_major` prints the major of `apt-cache policy nodejs` candidate or nothing.
- `node_install_action` prints exactly one of `ok` (installed major at least 18), `distro` (candidate at least 18), `nodesource`, per spec section 5 policy.
- `ensure_prerequisites <route>` installs only what `prereqs_missing` lists, starts/enables cron, installs Node per `node_install_action` (NodeSource 22 only when `ALLOW_NODESOURCE=true`, otherwise prints the exact command and exits 1), runs `npm ci --omit=dev`, honours `DRY_RUN` through `run_or_echo`; no system upgrade unless `MC_SETUP_UPGRADE_SYSTEM=true` (existing behaviour).
- `download_packages.sh` now sources `prereqs.sh` and calls `ensure_prerequisites power`.

- [ ] **Step 1: tests** (shims for `apt`, `apt-cache`, `sudo`, `node`, `npm` via PATH; `command -v` results controlled by shim presence): `test_installs_only_missing_packages` (jq present, curl missing: only `curl` installed), `test_whiptail_only_for_guided`, `test_node_ok_when_18_or_newer`, `test_node_action_distro_when_candidate_18`, `test_node_action_nodesource_when_candidate_12`, `test_nodesource_refused_without_flag` (exit 1, message contains the NodeSource setup command and `--allow-nodesource`), `test_nodesource_allowed_with_flag`, `test_no_system_upgrade_by_default`, `test_dry_run_installs_nothing`. Update `test_setup_flags.sh` to read the tool list from `PREREQ_COMMANDS`.
- [ ] **Step 2:** Implement `prereqs.sh`; reduce `download_packages.sh` to the caller. Keep the cron-service start/enable behaviour.
- [ ] **Step 3: Commit:** `feat: add prerequisite stage with node version policy`.

### Task 4: Route selection, new flags and the stage order

**Files:** Modify `main.sh`, `src/common/setup.sh` (`resolve_instance_vars`, `snapshot_setup_state`), `src/common/flags.sh`; Create `src/wizard/route.sh` (selector only in this task); Test `tests/shell/test_route.sh`, `tests/shell/test_main_flow.sh`.

**Interfaces:**
- New `ARG_OPTS` in `main.sh`: `--default` (`DEFAULT_ROUTE`), `--guided` (`GUIDED_ROUTE`), `--allow-nodesource` (`ALLOW_NODESOURCE`).
- `select_route` sets `ROUTE` to `default`, `guided` or `power`: `power` when `variables.json` exists, or stdin is not a TTY and neither `--default` nor `--guided` is given; `--default`/`--guided` force the route; otherwise a plain-text prompt (`1) Quick setup (recommended)  2) Guided setup`) with Default preselected. `--default` without a TTY requires `--agree-eula`, else exit 1 with a message.
- `main.sh` order: checks, `parse_args`, `--check` branch unchanged (including `ensure_variables_json`), `select_route`, then: power: `ensure_variables_json` (old create-and-exit behaviour) then `ensure_prerequisites power`; default or guided: `ensure_prerequisites <route>` then `run_wizard <route>` (stub that exits 1 until Task 12), then the existing flags, trap and pipeline.
- No `node` call occurs before `ensure_prerequisites`: `resolve_instance_vars`, `snapshot_setup_state` and `api_server_enabled_in_config` already run after it in the new order; verify and, where one still runs earlier, move it.

- [ ] **Step 1: tests:** `test_route.sh`: `test_existing_config_selects_power`, `test_no_tty_no_flags_selects_power`, `test_default_flag_forces_default`, `test_default_flag_without_tty_requires_eula` (exit 1, message names `--agree-eula`), `test_guided_flag_forces_guided`. `test_main_flow.sh`: `test_no_node_on_path_gives_clear_message` (run `main.sh` with `node` absent and the `apt` shim failing: output contains `Node` and never contains `variables.json is missing or invalid`), `test_power_route_missing_config_still_creates_and_exits` (exit 1, `variables.json` created from the example), `test_existing_flags_still_parse`.
- [ ] **Step 2:** Implement route selection and the `main.sh` reorder; keep the admin flag behaviour.
- [ ] **Step 3: Commit:** `feat: add route selection and bootstrap-first stage order`; `fix: stop reading config with node before it is installed` for any early-read moves.

**Wave 2 verification:** `bash tests/shell/run.sh test_prereqs.sh test_route.sh test_main_flow.sh test_setup_flags.sh test_setup_scripts.sh test_setup_rollback.sh`.

## Wave 3: Wizard core (spec section 6)

### Task 5: Validators

**Files:** Create `src/wizard/validators.sh`; Test `tests/shell/test_wizard_validators.sh`.

**Interfaces:** each `validate_<name> <value> [args]` returns 0, or 1 and prints one message saying what is wrong and what would work: `validate_port`, `validate_memory_size` (`^[0-9]+[GM]$`, at least 512M), `validate_int_range <min> <max>`, `validate_instance_name` (same rule as `INSTANCE_NAME` in `loadVariables.js`), `validate_free_port`, `validate_min_disk_gb <path> <gb>`, `validate_nonempty`, `validate_one_of <values...>`, `validate_webhook_url` (empty or `https://`), `validate_curseforge_pack_id`. `run_validators <value> <name[:arg]...>` runs a list and prints the first failure.

- [ ] **Step 1: tests:** at least one passing and one failing case per validator, with the message asserted for `validate_port` (`70000` says it must be 1-65535), `validate_memory_size` (`4g` rejected, says use `4G`), `validate_instance_name` (`my server` rejected). `test_validators_match_load_variables` feeds the same instance-name cases to the validator and to `node -e "require('src/setup/common/loadVariables')"` (skipped without node) and asserts agreement.
- [ ] **Step 2:** Implement. Reuse the regex from `loadVariables.js` verbatim.
- [ ] **Step 3: Commit:** `feat: add wizard validator library`.

### Task 6: Whiptail wrappers and shim

**Files:** Create `src/wizard/whiptail.sh`, `tests/shell/shims/whiptail`; Test `tests/shell/test_wizard_whiptail.sh`.

**Interfaces:** each wrapper prints the answer on stdout and returns 0 (answered), 10 (Back), or 11 (Cancel/exit); `wt_input <title> <text> <default>`, `wt_yesno <title> <text> <default:yes|no>`, `wt_menu <title> <text> <default> <tag> <label>...`, `wt_radiolist`, `wt_checklist`, `wt_password`, `wt_msgbox`. All size windows from `stty size` with minimums, use `--output-fd` (no stderr swapping), and map exit 0 to answered, 1 to Back, 255 to Cancel. `wt_available` rc 0 when `whiptail` exists, the terminal is at least 70x20 and `TERM` is not `dumb`.

- [ ] **Step 1: tests** with a scriptable shim (`WHIPTAIL_SHIM_REPLIES` lines of `rc|text`): `test_input_returns_text`, `test_exit_1_maps_to_back`, `test_exit_255_maps_to_cancel`, `test_unavailable_when_term_dumb`, `test_unavailable_when_terminal_too_small`, `test_checklist_returns_tags`.
- [ ] **Step 2:** Implement and write the shim (log every call to `$SHIM_LOG`).
- [ ] **Step 3: Commit:** `feat: add whiptail wrappers`.

### Task 7: Manifest and engine

**Files:** Create `src/wizard/manifest.sh`, `src/wizard/engine.sh`; Test `tests/shell/test_wizard_engine.sh`.

**Interfaces:**
- `wizard_manifest` prints one record per step, fields separated by a tab: `id`, `json_path` (dot path in `variables.json`), `type` (`string|number|bool|list`), `widget`, `default_spec` (literal or `detect:<function>`), `routes` (comma list of `default,guided`), `validators` (comma list `name[:arg]`), `when` (empty or `id=value`), `title`, `help`. Initial Guided steps: `instance_name`, `server_kind` (fabric, vanilla, modpack), `minecraft_version`, `memory`, `max_players`, `motd`, `difficulty`, `whitelist`, `optional_mods` (checklist), `backups`, `restart_schedule`, `webhook`, `api_wrapper`, plus the modpack steps `curseforge_key` and `curseforge_pack` shown only when `server_kind=modpack`. Default shows none.
- `engine_run <route>` loops over the steps for the route with an index so Back returns to the previous shown step (Back at the first step re-prompts), evaluates `when`, runs validators and re-asks with the message on failure, stores answers in `declare -A ANSWERS` keyed by `json_path`, returns 0 when finished, 11 on Cancel. `engine_available` is `wt_available`; when it fails mid-run the engine returns 12 and the caller falls back (Task 11).

- [ ] **Step 1: tests** (whiptail shim replays answers): `test_collects_answers_by_json_path`, `test_back_returns_to_previous_step`, `test_invalid_answer_reasks_with_message`, `test_when_condition_hides_modpack_steps`, `test_cancel_returns_11`, `test_unavailable_mid_run_returns_12`, `test_adding_a_manifest_entry_needs_no_engine_change` (a test-only manifest record appears in the answers).
- [ ] **Step 2:** Implement. No step-specific control flow in `engine.sh`.
- [ ] **Step 3: Commit:** `feat: add wizard manifest and engine`.

### Task 8: Config writer

**Files:** Create `src/wizard/config_writer.sh`; Test `tests/shell/test_wizard_config.sh`.

**Interfaces:** `config_write <out_path>` reads `declare -A ANSWERS` (json path to value) and the type from `wizard_manifest`, merges over `variables.example.json` with `jq`, then writes atomically: temp file in the same directory, `umask 077`, `mv`. Placeholders are blanked unless answered: `NOTIFICATIONS.WEBHOOK_URL` to `""`, `API_SERVER.API_KEY` to `""`; when `API_SERVER.ENABLED` is true a 64-hex key is generated from `/dev/urandom` (no openssl). Secrets are passed to jq with `--rawfile` or `$ENV`, never `--arg` on argv. Seeds stay strings.

- [ ] **Step 1: tests:** `test_unasked_keys_keep_example_defaults`, `test_answers_override_by_path`, `test_numbers_and_booleans_typed` (`MAX_PLAYERS` is a JSON number, `WHITELIST` a boolean), `test_placeholders_blanked`, `test_generated_api_key_is_64_hex_and_not_in_process_args` (key absent from the shim log of argv), `test_file_mode_is_600`, `test_atomic_write_leaves_no_partial_file_on_failure` (jq shim fails: output path absent, no temp left), `test_seed_stays_string`, `test_output_passes_load_variables` (skipped without node).
- [ ] **Step 2:** Implement.
- [ ] **Step 3: Commit:** `feat: add wizard config writer`.

### Task 8b: Server port setting

**Why:** setup never writes `server-port` (verified in `set_server_properties.js`), so a chosen port had no way into the server.

**Files:** Modify `variables.example.json`, `src/setup/common/loadVariables.js`, `src/setup/variables/set_server_properties.js`; Test `tests/js/loadVariables.test.cjs`, `tests/js/serverProperties.test.cjs` (extend).

**Interfaces:** new optional key `JAVA.SERVER.PORT` (integer 1 to 65535, default 25565 when absent). `loadVariables` rejects a non-integer or out-of-range value with the message `JAVA.SERVER.PORT must be a valid port number (1-65535).`. `set_server_properties.js` writes `server-port=<port>` through `applyProperties`. The wizard's `config_write` sets `JAVA.SERVER.PORT` only when the chosen port is not 25565.

- [ ] **Step 1: tests:** `loadVariables` accepts 25566, rejects 0, 70000 and "25565" (string); `set_server_properties` writes `server-port=25566` when set and `server-port=25565` when absent.
- [ ] **Step 2:** Implement; add `"PORT": 25565` to `variables.example.json` under `JAVA.SERVER`.
- [ ] **Step 3: Commit:** `feat: add a server port setting`.

**Wave 3 verification:** `bash tests/shell/run.sh test_wizard_validators.sh test_wizard_whiptail.sh test_wizard_engine.sh test_wizard_config.sh` and `node --test tests/js/loadVariables.test.cjs tests/js/serverProperties.test.cjs`.

## Wave 4: Safety rules, version resolution and the two routes (spec sections 4, 7, 9, 10)

### Task 9: Safety rules

**Files:** Create `src/wizard/safety.sh`; Test `tests/shell/test_wizard_safety.sh`.

**Interfaces (each records a correction through `correction_add` when it changes the value):**
- `safe_heap_mb <available_mb>` prints the heap in MB: reserve `max(1024, available*25/100)`, heap is the rest, capped at 8192, floored at 1024; `heap_to_java_size <mb>` prints `NG` for multiples of 1024 else `NM`. `alwaysPreTouch` is false when the heap is under 4096.
- `choose_heap <requested_mb|"">` returns the safe heap, correcting a request above the safe maximum (`adjusted`), and raising a `warning` correction when available RAM is under 1536 MB ("may be slow or fail").
- `choose_server_port` prints 25565 when free, else `detect_next_free_port 25566` plus a `warning` correction that states the chosen port and that it is the one to forward on the router; `choose_rcon_port` does the same from 25575.
- `choose_instance_name <base> <target>` prints `detect_free_instance_name` result and records an `adjusted` correction when it differs from `<base>`.

- [ ] **Step 1: tests:** `test_heap_rule_values` (available MB to heap MB: 1536 to 1024, 2048 to 1024, 4096 to 3072, 8000 to 6000, 16000 to 8192 by the cap, 64000 to 8192), `test_heap_request_above_safe_is_corrected`, `test_low_ram_raises_warning_but_returns_value`, `test_port_default_when_free_no_correction` (`corrections_count` 0), `test_port_busy_picks_next_and_warns_with_port_number`, `test_name_collision_picks_next_and_corrects`, `test_pretouch_off_for_small_heap`.
- [ ] **Step 2:** Implement. The cap (8192) and reserve numbers live as named constants at the top of the file.
- [ ] **Step 3: Commit:** `feat: add safe defaults for memory, port and instance name`.

### Task 10: Default version resolver (Node)

**Files:** Create `src/setup/download/resolve_default_version.js`; Test `tests/js/resolveDefaultVersion.test.cjs` (use `tests/js/axiosStub.cjs`).

**Interfaces:** CLI `node resolve_default_version.js [--groups performance,utility] [--lookback 3]` prints one JSON object on stdout: `{"minecraft": "<version>", "notices": [{"severity":"adjusted","text":"..."}], "dropped": ["<slug>"]}`; exit 1 with a message on network failure. Uses the Mojang manifest helpers in `download_utils.js` and `pickVersion` in `src/scripts/update/lib/versions.js`; mod slugs come from `src/vanilla/download/{performance,utility}_mods.txt` (handle CRLF). When no version in range supports every mod, it returns the newest version supported by the most mods and lists the rest in `dropped`.
- New optional config key `JAVA.SERVER.VANILLA.MODS.EXCLUDE` (array of mod slugs, default none): `loadVariables.js` validates it as an array of strings; `download_server.js` passes it to `download_mods.js` as `--exclude <comma list>`; `download_mods.js` skips those slugs (including as dependencies it would otherwise add only for them is out of scope: it only skips the listed slugs). Without this key an unavailable mod fails the whole install (download failure exits 1 and triggers rollback), so "dropped" mods need a way to be excluded.

- [ ] **Step 1: tests:** `latest_when_all_mods_support_it` (no notices, empty `dropped`), `falls_back_to_older_version_when_a_mod_lacks_a_build` (notice names the mod and both versions), `drops_mods_when_no_version_in_range_works` (newest-supported version, `dropped` lists the rest), `network_failure_exits_1`, `crlf_slug_files_are_read`; `loadVariables` accepts `["a","b"]` and rejects `"a"` and `[1]` for `EXCLUDE`; `download_mods` with `--exclude sodium` does not request `sodium` (extend `tests/js/setupDownloads.test.cjs`).
- [ ] **Step 2:** Implement. Reuse, do not copy, `pickVersion` and the manifest fetch.
- [ ] **Step 3: Commit:** `feat: resolve the newest minecraft version the default mods support`; `feat: add a mod exclude list for the vanilla and fabric setup`.

### Task 11: Default route

**Files:** Modify `src/wizard/route.sh` (add `run_wizard`, `run_default_route`), Create `src/wizard/summary.sh` (summary and final screen); Test `tests/shell/test_default_route.sh`.

**Interfaces:**
- `run_default_route` gathers answers without questions: name via `choose_instance_name server`, port via `choose_server_port` (written as `JAVA.SERVER.PORT` only when not 25565), heap via `choose_heap ""`, version via the Task 10 CLI (its notices become corrections, its `dropped` slugs are written to `JAVA.SERVER.VANILLA.MODS.EXCLUDE`), Fabric on, performance and utility groups on, optional off, backups and service on, API wrapper off; then `summary_render` (what will be installed, plain text, all corrections), the explicit EULA step (`eula_confirm`: shows `https://aka.ms/MinecraftEULA`, asks yes/no; with `--agree-eula` the answer is yes without asking), then `config_write variables.json`, then `wizard_apply_flags` (sets `NO_START=false NO_SERVICE=false NO_BACKUP=false SETUP_API_SERVER=false EULA=<answer> ACCEPT_ALL=true`).
- `run_wizard <route>`: default calls `run_default_route`; guided calls `engine_run guided`, then the same safety rules on the answers, `summary_render`, EULA step, `config_write`, `wizard_apply_flags`. If `engine_available` is false at start, or the engine returns 12, print a notice and run the Default route; Cancel (11) exits 0 with "nothing was changed". Declining the summary confirmation exits 0 with nothing changed.
- The failure message is printed by the `_rollback_if_needed` trap in `main.sh` after `run_rollback`.
- `final_screen` prints: where the server lives, how to join locally (`detect_local_ip` and the chosen port), the networking notice (spec section 9: same-network friends use local address and port; outside friends need the router to forward that TCP port to this machine and a public address or dynamic DNS name; the tool did not configure the router), the corrections again, and on failure "Your answers are saved in variables.json. Run again to retry, or delete it to start over."

- [ ] **Step 1: tests** (detectors and Node CLI shimmed): `test_default_route_writes_expected_config` (name `server`, version from the CLI, port absent when 25565 is free, performance and utility mods present), `test_default_route_declined_changes_nothing` (no file, exit 0), `test_eula_requires_explicit_yes` (without `--agree-eula` and answer no: no `variables.json`), `test_busy_port_and_low_ram_corrections_listed_on_summary`, `test_name_collision_uses_next_name`, `test_cancelled_guided_changes_nothing`, `test_guided_falls_back_to_default_when_whiptail_unavailable`, `test_final_screen_shows_port_and_forwarding_notice` (contains the actual chosen port and the words `router` and `forward`), `test_failure_screen_keeps_variables_json`.
- [ ] **Step 2:** Implement; wire `run_wizard` into `main.sh` replacing the Task 4 stub.
- [ ] **Step 3: Commit:** `feat: add default route`; `feat: add summary, eula step and final screen`.

### Task 12: Guided route and rollback behaviour

**Files:** Modify `src/wizard/manifest.sh` (complete help texts), `src/wizard/route.sh`; Modify `src/common/setup.sh` only to assert `run_rollback` never removes `variables.json`; Test `tests/shell/test_guided_route.sh`, extend `tests/shell/test_setup_rollback.sh`.

- [ ] **Step 1: tests:** `test_guided_flow_end_to_end` (shim answers choose Vanilla, 2G memory, 6 players: config reflects them), `test_guided_memory_above_safe_is_corrected_and_listed`, `test_guided_modpack_asks_curseforge_only_then`, `test_guided_rejects_existing_instance_name`, `test_ctrl_c_mid_wizard_leaves_no_variables_json` (kill during the engine: file absent), `test_rollback_keeps_variables_json`.
- [ ] **Step 2:** Complete the Guided steps and plain-language help (no jargon: explain RAM, version, whitelist in one or two sentences each).
- [ ] **Step 3: Commit:** `feat: add guided route`; `test: assert rollback keeps variables.json`.

**Wave 4 verification:** `bash tests/shell/run.sh test_wizard_safety.sh test_default_route.sh test_guided_route.sh test_setup_rollback.sh test_main_flow.sh` and `node --test tests/js/resolveDefaultVersion.test.cjs`.

## Wave 5: Xaero configuration (spec section 10)

### Task 13: Xaero config script and setup integration

**Files:** Create `src/scripts/misc/xaero_config.sh`; Modify `src/common/setup.sh` (new `run_post_mod_config` called after `run_server_setup`); Test `tests/shell/test_xaero_config.sh`.

**Interfaces:** `xaero_config.sh apply <server_dir>` and `xaero_config.sh check <server_dir>` (check prints one line per key `OK|DRIFT|MISSING|SKIP` and exits 1 on any DRIFT or MISSING). The table (verbatim from spec section 10): `config/xaero/lib/common.cfg` `everyone_tracks_everyone = true`; `config/xaero/minimap/common.cfg` `register_minimap_status_effects = false`; `config/xaero/world-map/common.cfg` `register_status_effects = false`. The `lib` key applies when either Xaero jar is in `mods/` (`xaerominimap*.jar`, `xaeroworldmap*.jar`); each other key only for its own jar; nothing is created when no Xaero jar exists. `apply`: file absent creates it containing only the key line (and parent dirs); file present replaces the value in place or appends the key; every other line, line endings and the file mode are preserved; idempotent.

- [ ] **Step 1: tests:** `test_creates_files_with_only_key_line_when_absent`, `test_patches_value_in_place_keeps_other_lines`, `test_appends_key_when_missing`, `test_idempotent_second_apply_no_change`, `test_crlf_file_stays_crlf`, `test_no_xaero_jar_creates_nothing`, `test_lib_key_when_only_one_mod_present`, `test_check_reports_drift_and_exit_1`, `test_file_mode_preserved`.
- [ ] **Step 2:** Implement with `grep`/`sed` on `key = value` lines (match on key with optional spaces; escape nothing from user input since keys are constants). Add `run_post_mod_config` to the setup pipeline (runs `apply` when the instance `mods/` has a Xaero jar; failure is a warning, not fatal).
- [ ] **Step 3: Commit:** `feat: patch xaero config keys to keep clients optional`.

### Task 14: Doctor check and update hook

**Files:** Modify `src/scripts/misc/doctor.sh`, `src/scripts/update/update-mods.js`, `src/scripts/update/add-mod.js` (success paths); Test extend `tests/shell/test_doctor.sh`, `tests/js/updateMods.test.cjs`.

- [ ] **Step 1: tests:** `test_doctor_xaero_drift_warns_with_fix_command` (WARN line names `xaero_config.sh apply`), `test_doctor_xaero_skip_without_jars`; JS: `runs_xaero_apply_after_a_successful_xaero_update` (child process stubbed; not run for other mods; failure logged, exit code unchanged).
- [ ] **Step 2:** Implement the doctor check using `xaero_config.sh check`. In the two Node scripts, after a successful install or update of a slug beginning `xaeros-`, run the deployed `misc/xaero_config.sh apply <SERVER_PATH>` through `execFile`, best effort; resolve the script path from the scripts directory that holds `common/variables.txt`.
- [ ] **Step 3: Commit:** `feat: report xaero config drift in doctor`; `feat: reapply xaero config after mod updates`.
- [ ] **Step 4 (verification step, not code):** record in the PR description whether the Xaero mods accept a file containing only the key line, by starting a throwaway server once with the pre-created files; if they do not, add the fallback from spec section 13 item 6 (start once, then patch and restart) as a follow-up commit on the branch.

**Wave 5 verification:** `bash tests/shell/run.sh test_xaero_config.sh test_doctor.sh` and `node --test tests/js/updateMods.test.cjs tests/js/addMod.test.cjs`.

## Wave 6: Documentation and finish

### Task 15: Docs, glossary, changelog

**Files:** Modify `readme.md`, `docs/GLOSSARY.md`, `CHANGELOG.md`.

- [ ] **Step 1:** README: add at the top a short "What is this", "Quick start" (`git clone`, `bash main.sh`), the three routes, and the networking notice (spec section 9); fix the known inconsistencies: Node described as installed automatically versus `npm install` first, API port default 3000 versus 3030, the missing comma and the `jsonc` presentation in the configuration snippet; document `--default`, `--guided`, `--allow-nodesource` in the options table.
- [ ] **Step 2:** GLOSSARY entries: **Route**, **Step manifest**, **Correction**, **Safe heap**. CHANGELOG: entries under the unreleased section in the file's existing style.
- [ ] **Step 3: Commit:** `docs: document onboarding routes and quick start`.

### Task 16: Full verification and the pull request

- [ ] **Step 1:** Run the whole suite once: `bash tests/shell/run.sh` (shell plus Node). Expected: `SHELL TESTS PASSED`, no skipped tests beyond hosts without a pty/node.
- [ ] **Step 2:** Run ShellCheck on the new files as the workflow does (`shellcheck -S warning` with the repo's `.shellcheckrc`).
- [ ] **Step 3:** Manual check on a clean Ubuntu 24.04 VM (not Docker): run `bash main.sh` from a fresh clone, Default route, to a running server; then repeat on a machine without Node and on Ubuntu 22.04 (NodeSource path). Record results in the PR.
- [ ] **Step 4:** Push the branch and open **one** pull request titled `feat: guided onboarding with default, guided and power-user routes` whose description lists the waves; no AI attribution lines.

## Self-Review

- **Spec coverage:** goals 1 to 9 map to Tasks 4, 11, 12 (routes), 9 and 11 (safety, loud corrections), 3 (only what is needed), 5 to 8 (modular wizard), 3 and 13 (Bash-first), 10 and 13 (mods, Xaero), 11 and 15 (networking notice). Section 5 and BC-001: Tasks 3 and 4. Section 7 rules: Task 9 (heap, port, name), Task 11 (existing installs, EULA, summary), Task 12 (rollback, variables.json). Section 8 boundary: validators vs `loadVariables.js` consistency test in Task 5 and 8. Section 11: Task 0 and 16 (branch, single PR), docs Task 15. Section 13 items 1 to 9: Tasks 3, 12, 9, 10, 4, 13, 2, 9, 11.
- **Gaps closed:** the optional BC-006 helper is not scheduled (spec marks it "only if cheap"; no task touches the three `variables.txt` writers).
- **Type consistency:** `ROUTE` values, `ANSWERS` keyed by json path, `correction_add` arity (five arguments) and the return codes 10, 11, 12 are used identically in Tasks 6, 7, 11, 12.
- **Proportion:** the plan states interfaces, test names with their key assertions, values pinned by the spec, and commit messages; function bodies are left to the implementer.
