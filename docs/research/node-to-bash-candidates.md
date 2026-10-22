# Research: Node to Bash migration candidates

Research date: 2026-10-21. Research only: nothing was migrated, rewritten, run or installed. Four subagents read the source in parallel (install-time Node, the update scripts and RCON, the world pruner plus reverse candidates, and tool availability); the report author read their notes and re-checked the load-bearing facts against the repo (setup order in `src/common/setup.sh`, the example config, the mod lists). Anything not read directly is marked.

Labels: **verified** = read in the source, a package index, an image manifest or a manual. **inferred** = reasoned from verified facts. **assumption** = depends on something not checked. Paths are relative to the repository root.

---

## 1. Executive Summary

**How much is Bash territory.** Of 47 Node files (about 9,400 lines), roughly 17 have a Bash-natural part, and almost none of them delivers a benefit that matters. The rest is HTTP/API work, nested JSON validation, hash-verified downloads, binary parsing (the 12-file world pruner, 3,593 lines) or a heavily tested state machine. There are 23 inline `node -e` calls in product Bash, and most of them are one-field reads of `variables.json`.

**Counts by rating (19 candidates):** High 1, Medium 5, Low 10, Not worthwhile 3. Of the 47 files, 31 are classified "stays in Node" (section 5, one line each; the 12 world files share one line).

**The few highest-value moves**
1. **BC-001 (High): make the bootstrap work before Node exists.** `resolve_instance_vars` (`src/common/setup.sh:123`), `snapshot_setup_state` (`:209`) and `api_server_enabled_in_config` (`src/common/flags.sh:16`) all call `node` before `download_packages.sh` installs anything. On a host without Node the user sees "variables.json is missing or invalid" because `2>/dev/null` hides "node: command not found". The fix is ordering (prerequisites first, then reads), not a language port: jq is also installed late, so swapping `node -e` for jq at those sites gains nothing. The README contradicts itself: it says `npm install` comes first and also that Node is installed automatically.
2. **BC-002 (Medium): collapse the duplicated operation lock.** `src/scripts/update/lib/opLock.js` (187 lines) is a JavaScript copy of the lock in `src/scripts/common/utils.sh`, and the two already behave differently (a holder owned by another user is treated as dead in Bash and alive in Node; Bash fails at once, Node waits 60 s). The cheap fix is the pattern `world/prune-chunks.js` already uses: re-exec through Bash. No file has to move.
3. **BC-003 (Medium): Java/Jabba selection into Bash.** The part of `install_java.js` that picks, installs and records a Jabba JDK is a Node wrapper around a sourced Bash function, and the same logic exists a second and third time in `update-server.js` and `install_jabba.sh`. It is the only move that removes an npm dependency (`semver`, used by this one file).

**Clearest "stays in Node":** `loadVariables.js` (about 50 nested rules with precise errors; BC-019), the world pruner, `download_utils.js` and the other hash-verified downloaders, `add-mod.js`, and `rcon.js`.

**Sharpest risk.** Moving JSON handling to `jq` writes through `mv`, which drops a file's mode and ACL. That bites `api-server-config.json` (mode 0600 plus a service-user ACL holding the API key and RCON password). A second risk is that `jq` 1.6, shipped on Debian 12 and Ubuntu 22.04, turns 64-bit integers into doubles, which matters for seeds.

**Where Bash-first, pursued literally, makes the tool worse.** Porting `upgrade-server.js` (the path that restores world data), `rcon.js`, `loadVariables.js` or `install_api_server.js` trades tested code for untested Bash and creates duplicated rules, with no dependency removed. Also, no move removes `axios` or the Node install step: Node is needed at runtime for RCON, the update scripts, the pruner and the API wrapper.

**Main limitations.** Nothing was run. The 3,593 lines of world code were judged from headers, function lists and the benchmark document. `migrate.sh`, `migrate-lib/plan*.sh`, `server_migrations.sh`, the body of `vanilla/start.sh` and the API wrapper repo were not read in full. Debian cloud image contents are unknown (Debian publishes no package manifest).

---

## 2. Current Split

### 2.1 Where Node runs

| Stage | What runs | Node needed? |
|---|---|---|
| Entry (`main.sh`) | `check_root`, `require_sudo`, `ensure_variables_json`, `parse_args` | No |
| Config reads before packages | `flags.sh:16`, `setup.sh:58`, `:209` (`node -e`, stderr discarded) | **Yes, before Node is installed** |
| `download_packages.sh` (apt) | installs curl, screen, unzip, nodejs, npm, cron, jq, rsync, zstd, acl, then `npm ci --omit=dev` | Installs it |
| Install-time Node (`run_or_echo "node ..."`) | `src/setup/**` (13 files), `src/vanilla/**` (3 files), 23 inline `node -e` | Yes |
| Runtime, Bash only | systemd unit (`screen -DmS ... bash start.sh`), cron (backup, cleanup, scheduled restart), `webhook.sh` | No (RCON mode: yes) |
| Runtime Node | RCON via `node rcon.js` (only when `USE_RCON=true`), update scripts, `upgrade-server.js`, `prune-chunks.js`, the API wrapper | Yes |
| `migrate.sh` | Bash, with Node for JSON merge and edits | Degrades without Node |

### 2.2 Seams

- **`variables.json`** (strict JSON, secrets) is read by Node scripts and by 23 inline `node -e`. **`variables.txt`** (written by Node, `KEY="value"` with four escapes) is `source`d by Bash, parsed without executing by `src/scripts/update/lib/variables.js`, and read by `sed`/`grep`/`cut` in `manage.sh:78` and `create_service.sh:22`. **`downloaded_versions.json`** is written by five Node paths and read by Node and by `check_updates.sh`. **`api-server-config.json`** (0600 plus ACL) is written by Node and read by the wrapper.
- **Wrapper contract (other repo, `minecraft-server-api`):** it runs mod scripts as `interpreter("node") <script>.js --json -- <slug>`, expects exactly one JSON object on stdout, and uses exit 75 for "busy". `src/setup/management/service_user.sh:138-145` builds sudoers aliases (`$n` for the node scripts, `$b` for `upgrade.sh`). A script that changes interpreter must change in both repos plus the sudoers rules.
- **Lock:** Bash `acquire_operation_lock` and Node `opLock.js` implement one protocol (flock, mkdir fallback, `.kind` file, exit 75, `MC_OPERATION_LOCK_HELD`). `prune-chunks.js` re-execs through Bash.

### 2.3 npm dependencies and what a move could remove

| Package | Used by | Removable by |
|---|---|---|
| `semver` (root) | `src/vanilla/download/install_java.js` only | BC-003 |
| `axios` (root and `src/scripts/update/package.json`) | `add-mod`, `check-updates`, `update-server`, `lib/download.js`, and the setup downloaders (`download_modpack`, `download_mods`, `download_utils`, `download_server`) | Not by any in-scope move. `lib/download.js` is imported by Node setup code, so axios and the second `npm ci` (setup and `restore.sh:235-245`) only go if **both** the update tools and the setup downloaders leave Node |

### 2.4 Tests

Bash: 251 test functions in 19 files with 14 shims (strong failure injection for tar, zstd, curl, lock, rollback; `jq` is shimmed to `{"shim":true}`, so real JSON payloads are never asserted). Node: about 295 tests in 22 files (132 for the pruner). CI runs `bash tests/shell/run.sh` on `ubuntu-latest` with Node 22 only, so there is no Ubuntu minimal image, no Node 18, and no Bash 4.3. No test runs `main.sh` end to end or on a host without Node. The 25 JS test files cover `loadVariables`, `properties`, `install_api_server`, the downloaders and the update scripts; none was found for the `set_*` writers, `install_java`, `download_server` or `create_api_server_service`.

---

## 3. Criteria

**Bash is the better fit when:** the code runs before Node exists; it orchestrates system binaries (apt, systemd, cron, exit codes); it detects the environment from the system; it edits simple line or key files; it is short-lived and infrequent; or the Node code mostly shells out already.

**Node keeps it when:** it does HTTP/API work; it handles nested JSON with precise errors; it verifies checksums or binary data; it needs concurrency; it uses real data structures; it has meaningful test coverage; or a quoting bug would be silent and damaging (mod jar deletion, world data, secrets).

**Ratings.** High: a benefit that matters (works before Node exists, or removes a real dependency or install step) with modest effort and low risk. Medium: a real benefit offset by effort, new dependencies or risk. Low: marginal, mainly consistency. Not worthwhile: possible, but the cost exceeds the return.

**Cost dimensions checked per candidate:** rewrite effort, lost tests, Bash hazards (quoting, `set -e` with `||` lists, pipelines hiding exit codes, subshell scope, cron's minimal PATH), new dependencies on a minimal image, **duplicated rules across languages**, error quality for a non-IT user, and single-maintainer readability.

**Existing Bash hazards that raise the bar for adding Bash (verified):** `set -e` is the norm but `pipefail` appears in only 10 files; `run_or_echo` evaluates a command string (`src/common/logging.sh:12`); crontab lines set no `PATH`; any new script must be added to the sudoers rules in `service_user.sh`.

---

## 4. Candidates

Ordered by rating. Effort is relative to this codebase.

| ID | What | Effort | Risk | New deps | Rating |
|---|---|---|---|---|---|
| BC-001 | Bootstrap order and pre-Node config reads | Small | Low | none (jq only if after install) | High |
| BC-002 | Operation lock in `opLock.js` | Small-Medium | Medium (mutual exclusion) | none | Medium |
| BC-003 | `install_java.js` Jabba part | Medium | Medium | none (coreutils `sort -V`) | Medium |
| BC-004 | `update-server.js` webhook and Jabba/`JAVA=` parts | Medium | Medium | none | Medium |
| BC-005 | `create_api_server_service.js` + `writeRootFile.js` | Medium | Medium (mode/ACL, secrets) | jq | Medium |
| BC-006 | One `variables.txt` upsert helper (3 Node writers) | Small | Low-Medium | jq | Medium |
| BC-007 | `set_common_variables.js` | Small-Medium | Medium (silent escaping) | jq | Low |
| BC-008 | `set_update_variables.js` | Small | Low | jq | Low |
| BC-009 | 4 post-install `node -e` reads | Small | Low | jq | Low |
| BC-010 | `check-updates.js` | Small-Medium | Medium (rule in 2 languages) | curl, jq | Low |
| BC-011 | `remove-mod.js` | Small | **High (jar deletion)** | jq | Low |
| BC-012 | `toggle-mod.js` + `toggle-mod-common.js` | Small | Medium | jq | Low |
| BC-013 | `install_api_server.js` | Large | High (atomic swap) | curl, jq, tar | Low |
| BC-014 | `rcon.js` | Medium | High (binary protocol) | `/dev/tcp`, od, dd, timeout | Low |
| BC-015 | `update-server.js` interactive mode | Medium | Low-Medium | none | Low |
| BC-016 | `manifest.js` reader | Small | Medium (writer race) | jq | Low |
| BC-017 | `upgrade-server.js` | Large | **High (restores world data)** | jq, timeout | Not worthwhile |
| BC-018 | `json_config.sh` merge and migrate JSON edits | Medium | Medium (format drift) | jq | Not worthwhile |
| BC-019 | `loadVariables.js` (final validation) | Large | High (about 50 rules duplicated) | jq | Not worthwhile |

### BC-001: Bootstrap order and pre-Node config reads (High)

- **Files/responsibility:** `src/common/setup.sh:123` (`resolve_instance_vars`), `:209` (`snapshot_setup_state` via `_rollback_paths`), `src/common/flags.sh:16`; the order of `download_packages.sh`.
- **Why Bash fits:** this is the only place in the codebase where "works before Node exists" applies. The reads run before `download_packages.sh`, so on a bare image they fail with a misleading message (verified from the code order; two agents found it independently). There is also no Node version check anywhere: `node -v` is only printed, `engines` is advisory, and no distro ships a supported Node (section 7.3).
- **How:** an ordering change in Bash: a first Bash stage installs the prerequisites that are needed (including a Node of at least 18, the one dependency that is not a one-line apt install, see section 7.3), then runs the reads and the validator. Replacing the three `node -e` reads with `jq` alone does **not** help, because jq is installed in the same late step and is absent from Ubuntu's minimal image. If the design generates `variables.json` itself through a Bash wizard, the early reads disappear (the config is created after the prerequisites are in place).
- **Benefits:** a bare image gets a clear message or a working install instead of "variables.json is missing or invalid"; the README contradiction (Node "installed automatically" vs `npm install` first) is resolved.
- **Risks:** low for the reorder; installing a current Node adds a third-party repository or a per-user manager (section 7.3). `resolve_instance_vars` returns early without validating when `INSTANCE_NAME` and `TARGET_DIR_NAME` are already exported (`:53-55`); any consumer that trusts the earlier validation inherits that gap. Rule duplication: none introduced.
- **Dependencies introduced:** none, or jq/Node earlier in the order.
- **Effort:** small. **Rating: High** (the one change that makes setup work before Node exists and fixes a user-visible failure). **Confidence:** verified.

### BC-002: Operation lock in `opLock.js` (Medium)

- **Files:** `src/scripts/update/lib/opLock.js` (187 lines); counterpart `src/scripts/common/utils.sh:96-140` (`acquire_operation_lock`).
- **Why Bash fits:** Node cannot hold a flock, so the file re-implements the Bash lock and re-runs the script as a child under `flock -w 60 -E 75` or a mkdir lock. The copies already diverge (verified): Bash `! kill -0` treats EPERM as dead, Node treats EPERM as alive; Bash acquires non-blocking (`flock -n`), Node waits up to 60 s; test hooks (`MC_TEST_LOCK_WAIT`, `MC_TEST_NO_FLOCK`) exist only in the JS suite. `utils.sh` also contains two near-identical mkdir blocks, and `prune-chunks.js` uses a third approach.
- **How (two routes):** (A) move all mod scripts to Bash (the sum of BC-010 to BC-012 plus add/update, mostly not recommended). (B), the cheap one: replace the body of the Node guard with the pattern `prune-chunks.js:222` already uses: `bash -c 'source load_variables.sh; source utils.sh; acquire_operation_lock mods || exit 75; node "$@"'`. About 187 lines become about 30. A blocking variant of `acquire_operation_lock` is needed to keep the 60 s wait, or the wait is dropped and the wrapper sees "busy" at once. The five lock tests in `removeMod.test.cjs` shrink; `test_operation_lock.sh` gains the wait case.
- **Benefits:** one lock implementation and one fix location; the EPERM fork gets a deliberate decision.
- **Risks:** this guards mutual exclusion for restore, rollback and upgrade; a lock change can look green and still allow two holders. `load_variables.sh` aborts under `set -e` on a half-configured install, whereas Node currently falls back to the lock name `default`. Duplication: removes a duplicated rule.
- **Dependencies:** none. **Effort:** small-medium (route B). **Rating: Medium** (removes a proven divergence; no dependency or install step goes away). **Confidence:** verified (divergence), inferred (practical EPERM impact).

### BC-003: `install_java.js` Jabba selection (Medium)

- **Files:** `src/vanilla/download/install_java.js` (121 lines).
- **Why Bash fits:** the file resolves a Java major through Mojang metadata (HTTP and JSON, stays Node), then shells out twice to `bash -c '. ~/.jabba/jabba.sh && jabba ...'`. Node is a quoting wrapper around a Bash function, and the `CANDIDATE_RE` guard exists only because Node builds a shell string. It writes `JAVA="..."` into the instance `variables.txt` with unescaped quoting. It is the **only user of `semver`**.
- **How:** a Bash step after `install_jabba.sh`: source `jabba.sh`, `mapfile` the `jabba ls-remote` output filtered for `adopt@<major>.` and `temurin@<major>.`, pick the newest with `sort -V` on the part after `@`, validate with `[[ =~ ^[A-Za-z0-9._@+-]+$ ]]`, `jabba install` and `jabba use`, then write the `JAVA=` line through the BC-006 helper. The Java major arrives from a new tiny seam: a small Node CLI that prints the major (keeps HTTP in Node), or curl plus jq on the Mojang manifest (which duplicates `getJavaVersionFor`, still needed by `download_server.js`).
- **Benefits:** removes `semver` (root `package.json` then lists axios only) and the Node to `bash -c` quoting layer.
- **Risks:** `sort -V` against `semver.coerce` on strings like `temurin@21.0.5+11` or `adopt@1.8.0-292`, with ties between adopt and temurin resolved differently; an empty filter result under `set -e` plus `pipefail` (grep exits 1) must still print "No Jabba candidates for Java N"; `jabba.sh` strict-mode behaviour is an assumption; use `LC_ALL=C` and `timeout 120` for `ls-remote`.
- **Dependencies:** coreutils `sort -V`, awk (mawk is the default awk on every Debian/Ubuntu release; avoid gawk-only features). **Effort:** medium (121 lines, no existing tests, one new seam). **Rating: Medium** (drops a real, small dependency). **Confidence:** verified, with the jabba strict-mode behaviour an assumption.

### BC-004: `update-server.js` webhook and Jabba/`JAVA=` parts (Medium)

- **Files:** `src/scripts/update/update-server.js` (730 lines): `sendWebhook` (lines 158-186), `installJabbaVerified`, `findInstalledJava`, `compareJdkNames`, `setServerJava`, `lib/jabba.js`.
- **Why Bash fits:** `sendWebhook` reimplements `src/scripts/common/webhook.sh` (payload shape, Discord detection, event filter); `upgrade-server.js` already calls the Bash `notify`. The Jabba pin (URL plus SHA-256) is also in `install_jabba.sh` ("keep in sync"), the JDK sort is a hand-rolled `compareJdkNames` here and `semver` in BC-003 (two sort rules for one decision), and `JAVA=` rewriting is key=value editing.
- **How:** call `notify` for the webhook (a one-line change); share one Bash Jabba function between the vanilla install and update paths; `sort -V` on the version part; `JAVA=` through BC-006's helper with mode preserved.
- **Benefits:** removes three copies of one rule; `webhookEvents.test.cjs` and `test_webhook.sh` stop testing two implementations of one format.
- **Risks:** Bash `notify` silently skips without jq, Node posts without it (behaviour change); the Java path is validated in Node (`^[A-Za-z0-9._/+@-]+$`) and must stay validated; `sort -V` edge cases on `+` and `_` suffixes. Only four unit tests cover this 730-line file; Mojang resolution, `--plan`, `--apply`, the Fabric installer path and `ensureJavaVersion` have no test, so the "tested code" argument is weak for these parts. The Mojang/Fabric HTTP, `downloadVerified` and the NDJSON emit stay Node (the file is MIXED).
- **Dependencies:** coreutils only. **Effort:** medium. **Rating: Medium** (deduplication of user-visible and security-relevant rules; no dependency removed). **Confidence:** verified for structure.

### BC-005: `create_api_server_service.js` and `writeRootFile.js` (Medium)

- **Files:** `src/setup/management/create_api_server_service.js` (230 lines), `src/setup/common/writeRootFile.js` (40).
- **Why Bash fits:** about 120 of 230 lines are sudo/systemd/ACL orchestration (`sudo tee`, `sudo systemctl daemon-reload/enable/start`, `setfacl`, `command -v node/bash`); the Bash twin `create_service.sh` already does the same for the instance unit. `variables.txt` is designed to be sourced by Bash.
- **How:** keep `install_api_server.js` as the installer (its exit code drives `set -e`); write the unit through a heredoc piped to `sudo tee`; merge `api-server-config.json` with `jq --arg ... '.instances[$n] = {...}'` into a `mktemp` file in the same directory; then `mv`, `chmod 600` **and** `setfacl -m u:$svc:r` in that order (chmod resets the ACL mask).
- **Benefits:** one fewer Node entry point at setup; the unit-writing idiom exists once; the SERVICE_USER regex, defined three times today (`loadVariables.js:86`, `create_api_server_service.js:44`, `service_user.sh:66`), loses one copy.
- **Risks:** `jq > tmp && mv` replaces the inode and drops the file's mode 0600, owner and the service user's ACL (the Node version writes in place and re-asserts them); RCON password and API key must not travel on an argv visible in `ps` (use `--rawfile` or `$ENV`); `local x=$(...)` masks failures; `sudo systemctl` inside `if !` disables `set -e`. No existing tests, so none are lost; `tests/shell/shims` already has sudo and systemctl.
- **Dependencies:** jq (installed by `download_packages.sh`; absent on noble minimal and every jammy image before that step), `setfacl` (acl package is on no Ubuntu image by default). **Effort:** medium. **Rating: Medium** (consistency and fewer moving parts; the wrapper needs Node anyway). **Confidence:** verified for behaviour, inferred for `mv` semantics.

### BC-006: One `variables.txt` upsert helper (Medium)

- **Files:** `set_server_variables.js`, `set_vanilla_server_variables.js`, `install_java.js` (all upsert lines in the instance `variables.txt` in three different ways), plus the readers in `manage.sh:78`, `create_service.sh:22`, `migrate-lib/structure.sh:59`, `recovery.sh:51`.
- **Why Bash fits:** `variables.txt` is a Bash-sourced key=value file; a single `set_var FILE KEY VALUE` and a single `get_var` would replace three Node implementations and four ad-hoc `sed`/`grep` readers/editors.
- **How:** `grep -v '^KEY='` into a temp file, `printf` the new line with the four-escape quoting (`\ " $ backtick`), then `cat tmp > file` (keeps mode and ACL) or `chmod --reference`; the reader sources in a subshell or parses and unescapes.
- **Benefits:** one escaping rule on the writer side; fixes a verified reader bug (`sed` does not unescape a path with `"`, `\` or `$`) and the unescaped `sed -i "s|path|..."` edits in `migrate-lib` (a path containing `|`, `&` or a regex character is edited wrongly).
- **Risks:** `grep -v` with no match returns 1 under `set -e`; JS keeps a key with leading whitespace that an anchored grep misses; the reader `lib/variables.js` (Node) still has to undo exactly the same escapes, so the rule lives in two languages (writer in Bash, reader in Node); no test pins the contract today (a round-trip `source file; compare` test is simple).
- **Dependencies:** jq only if the value comes from `variables.json`. **Effort:** small. **Rating: Medium** only if all three upserts move together; Low alone. **Confidence:** verified.

### BC-007 to BC-016 (Low)

- **BC-007 `set_common_variables.js` (96 lines):** writes about 24 `KEY="value"` lines into `variables.txt` with `shDquote`. Bash fits (Bash-sourced output, short, one-shot); `printf %q` is not usable (the Node parser and `cut -d'"'` readers expect the double-quoted form). Risks: JS `||`, `??`, `!== false` defaults versus jq `//` (which treats `false` and `null` as absent, so `SKIP_IF_EMPTY` needs an explicit test); secrets must not go on argv; silent escaping errors with no test. The escape rule would then live in Bash (writer) and Node (reader). Effort small-medium. Low.
- **BC-008 `set_update_variables.js` (30 lines):** writes `API_KEY='...'` to `curseforge.txt`. Bash: `jq -r '.api_key // ""'`, then `printf` with `'\''` escaping under `umask 077`. Saves one Node start (inferred). Risk: a silent quote-expansion error with a key containing `'`. Effort small. Low.
- **BC-009 four post-install `node -e` reads:** `setup.sh:10`, `:178`, `:370`, `:371` can become `jq -r '.A.B // default'`. The other reads run before packages or inside `--check`, which must work without jq, and two are validator calls (`:58`, `:413`, `:417`) that are not jq-replaceable. Fixing the 14-spawn preflight is better done by one structured read (see section 6). A latent bug is visible here: `setup.sh:457-458` prints the string "undefined" when a CurseForge key is missing, so `--check` reports it as configured. Effort small. Low.
- **BC-010 `check-updates.js` (219 lines):** read-only, two curl calls per mod plus a jq filter; Bash precedent exists (`src/scripts/misc/check_updates.sh`). Risks: `pickVersion` (release over beta over alpha, newest first) would exist in jq and in `lib/versions.js` (still needed by `add-mod` and `download_mods.js`); `curl --fail` loses Modrinth's JSON error body (`--fail-with-body` needs curl 7.76 or newer, and Ubuntu 22.04 ships 7.81 and Debian 12 ships 7.88 but Debian 11 ships 7.74, inferred); Modrinth wants a descriptive User-Agent; slugs contain `!`, `$` and quotes; four tests rewritten; wrapper plus sudoers (`$n` to `$b`) changes in two repos. Does not remove axios. Low.
- **BC-011 `remove-mod.js` (158 lines):** no HTTP, an `rm` of a named file plus `jq 'del(.mods[$k])'`. Risk class: the S-008 bug ("removing sodium deleted sodium-extra") came from exactly the slug-scan regex and glob, and slugs contain regex metacharacters; Node waits 60 s on the lock while Bash is `flock -n`; 14 tests (11 not about locking) rewritten. Low.
- **BC-012 `toggle-mod.js` + `lib/toggle-mod-common.js` (218 lines):** a `mv -n --` between two directories plus a manifest lookup; the safest of the mod scripts to move, but only 3 tests cover it. Low.
- **BC-013 `install_api_server.js` (250 lines):** mostly curl, sha256sum, tar, npm, `mv` and getfacl/setfacl, and `migrate.sh` is Bash. But it has 13 tests including atomic-swap rollback ("old install or new, never a mix"), a local HTTP release server, and sha256 mismatch behaviour. A `curl --proto =https` port would be stricter than `fetch` (a behaviour change; the mirror test uses http). Large effort. Low.
- **BC-014 `rcon.js` (177 lines):** a Bash port via `/dev/tcp` is feasible (inferred): packets built with `printf` escapes (NUL cannot live in a Bash variable), replies read with `dd`/`od`, `timeout` for the deadline, the empty-sentinel trick for multi-packet replies. The binary protocol already produced S-010 (exit 0 on close-before-answer) and BUG-02 (unbounded length); a mis-sized `dd` read hangs until the timeout. Gains: no Node per call in polling loops, and the `node` requirement for RCON mode (`validate.sh:62-77`) disappears. `screen -X stuff` cannot replace it (no reply, so no completion signal for `save-all flush`). Low.
- **BC-015 `update-server.js` interactive mode:** `readline` prompts, `backupServer`, `disableMods`, `runModUpdate` are orchestration plus Q&A; a Bash driver would call `update-server.js --plan/--apply`, the contract `upgrade-server.js` already uses. The interactive path is a convenience (the supported flow is `upgrade.sh`). Low.
- **BC-016 `lib/manifest.js` reader:** the reader fits `jq -e` with an explicit parse error; the fsync plus `O_EXCL` writer should stay Node while any Node writer remains. There are five writers of `downloaded_versions.json`, so the "one reader and writer" comment is not true in practice, and a mixed Bash/Node writer set loses updates in a read-modify-write race (the setup-time writer runs before any lock exists). Low.

### BC-017: `upgrade-server.js` + `upgrade.sh` (Not worthwhile)

- **Files:** `src/scripts/update/upgrade-server.js` (488 lines).
- **Why it looks Bash-shaped:** it only orchestrates processes and exit codes, polls two logs by byte offset, sleeps and writes NDJSON; the tree today is Bash (`upgrade.sh`), Node, Bash (instance ops, backup, restore), Node (`update-server`), Node (children).
- **How:** `timeout` for step ceilings, `tail -c +N` for log tails, `jq -nc` for each NDJSON line with a counter, `trap` for rollback, the existing shims for tests.
- **Why not:** it is a dependency-injected state machine (24 tests run in-process with no process, clock or filesystem) and the one path that restores world data from backup. A Bash port means `set -e` with `||` lists disabling `-e`, globals instead of injected dependencies, byte-compatible NDJSON for the wrapper's poller, and the loss of the most behavioural test suite in the repo. No dependency is removed (it still calls Node scripts). Effort large. **Not worthwhile.** Worth a second look only if `update-server.js`, `toggle-mod.js` and the pruner also left Node.

### BC-018: `json_config.sh` merge and the migrate JSON edits (Not worthwhile)

- **Files:** `migrate-lib/json_config.sh` (45 lines; recursive merge where existing values win, result written into the new file), `recovery.sh:34`, `structure.sh:86`, `verify.sh:29`.
- **Why not:** this is Bash calling Node for the right reason (nested JSON, paths passed through `process.argv`, no interpolation). A `jq -s '.[1] * .[0]'` port changes key order (follows the left file instead of the existing file), re-renders numbers, needs a temp file and `mv`, and drops the mode/ACL that the in-place Node write keeps. Moving the `serverPath` edits to jq has the same mode/ACL problem. **Not worthwhile.**

### BC-019: `loadVariables.js` final validation (Not worthwhile)

- **File:** `src/setup/common/loadVariables.js` (277 lines).
- **Why not:** it holds about 50 rules (regexes, integer ranges, divisibility of `INTERVAL_HOURS`, GC-specific required keys, webhook event list, memory formats, a `/proc/meminfo` warning) with first-error precise messages, and it is the single authority six Node scripts import. A Bash copy would duplicate every rule in a second language and lose its tests. `jq` also cannot read JSONC (no manual or the source accepts comments or trailing commas), so a hand-edited config with a stray comment would give `jq: parse error: ... at line L, column C` with no file name. A wizard-generated `variables.json` does not change this: the wizard can check what it asks, but Node stays the last line of defence. Duplication today is already visible (API-key placeholder and 32-character rule in both `loadVariables.js` and the Bash preflight at `setup.sh:525-530`; the webhook events list in JS, Bash and README, guarded by a test). **Not worthwhile.**

---

## 5. Stays in Node (one sentence each)

- `src/setup/common/properties.js`: tested escaping rules where an sed/awk port would silently corrupt on `&`, backslash and awk `-v` processing.
- `src/setup/download/json/load.js`: a trivial helper that exists only for its JS callers.
- `src/setup/download/download_utils.js`: timeouts, size caps, https-only redirects, SHA-1 verification and the version ledger shared with the runtime Node tools.
- `src/setup/download/download_modpack.js`: an authenticated multi-step CurseForge API sequence plus a hash-verified download.
- `src/setup/download/download_mods.js`: recursive Modrinth dependency resolution using the shared, tested `pickVersion`.
- `src/setup/variables/set_server_variables.js`: a nested-JSON flag builder whose output `start.sh` later word-splits unquoted, so a Bash quoting slip would be silent and damaging.
- `src/setup/variables/set_server_properties.js`: a thin consumer of the tested `properties.js` and of validated JSON.
- `src/vanilla/download/download_server.js`: Mojang and Fabric metadata lookups plus checksum-verified downloads on the shared Node downloader.
- `src/scripts/update/add-mod.js`: HTTP error shaping, filename sanitising, verified download and dependency logic where a bug lands the wrong jar in `mods/` (25 tests).
- `src/scripts/update/update-mod.js`: a thin wrapper over `update-mods.js`.
- `src/scripts/update/update-mods.js`: download, rename-before-delete and manifest sequencing with partial-failure semantics that must not break.
- `src/scripts/update/lib/args.js`: a small helper shared with `prune-chunks.js` and not worth a rewrite alone.
- `src/scripts/update/lib/download.js`: the integrity gate for jars that get executed, imported by Node setup code that is not moving.
- `src/scripts/update/lib/jabba.js`: a 25-line validator imported by two Node files (it disappears if BC-003 and BC-004 happen).
- `src/scripts/update/lib/jars.js`: follows its consumers.
- `src/scripts/update/lib/json-mode.js`: a Node-specific console-patching mechanism that disappears with its consumers.
- `src/scripts/update/lib/variables.js`: a non-executing parser of `variables.txt` that Node genuinely needs.
- `src/scripts/update/lib/versions.js`: the `pickVersion` rule is shared by setup and update code.
- `src/scripts/world/prune-chunks.js`, `lib/plan.js`, `lib/nbt.js`, `lib/region.js`, `lib/tiles.js`, `lib/world.js`, `lib/scan.js`, `lib/scanWorker.js`, `lib/pool.js`, `lib/cache.js`, `lib/ensure.js`, `lib/blockColors.js` (12 files, 3,593 lines): binary region/NBT parsing, zlib inflate, PNG output and worker threads; the benchmark document measures a 1.01M-chunk world at 268 s single-threaded against 27.7 s with workers, so a per-chunk fork in Bash is orders of magnitude slower.
- `src/setup/common/loadVariables.js`: see BC-019.

---

## 6. Reverse Candidates (Bash that would be better in Node, or fixed in place)

- **R1 `src/scripts/misc/check_updates.sh` (98 lines), High, small effort:** parses `downloaded_versions.json` with `tr -d` and a `"mods":\{([^\}]*)\}` regex. Node now writes mods as `{versionId, filename}` objects (`download_utils.js:195`), so the `[^\}]*` stops at the first `}` and file ids come out wrong (read on both sides; not run). Its only test uses the old flat fixture, so it stays green. No caller was found in this repo or the wrapper repo, so it is probably manual-only. `check-updates.js` already does the same job: retire or replace it.
- **R2 `variables.txt` handling:** three writers use three quoting schemes; Bash readers use `cut -d'"'` and `sed` that never unescape; `migrate-lib` edits use unescaped `sed -i "s|path|...|"`. See BC-006. A safe Bash fix exists, so this is not a language argument.
- **R3 `node -e` with the path interpolated into JS and stderr discarded:** 14+ sites in `setup.sh` and `flags.sh`. An apostrophe or backslash in `$SCRIPT_DIR` breaks the JS, and the failure becomes an empty value read as "disabled". The preflight spawns Node 14 times to read single fields from one file; one structured read would remove the repeated spawns, the duplicated API-key rules and the "undefined" bug. (`migrate-lib/json_config.sh` passes paths through `process.argv`, so it is fine.)
- **`src/vanilla/start.sh` `_json_string`/`emit_event`:** hand-rolled JSON escaping covers `\ " \n \r \t` only; other control characters would yield invalid NDJSON. Unlikely; kept in Bash on purpose (runs under systemd without Node).
- **`create_service.sh:22`:** a `sed` read of `BACKUPS_PATH` without unescaping (small, rare).
- **`migrate-lib/api_wrapper.sh`:** parses a `state=... installed=... pinned=...` line from `install_api_server.js --check`; a `--json` flag would be sturdier. Low.
- **`utils.sh`:** two copies of the flock/mkdir/stale-takeover block inside Bash; a Bash refactor, not a language change.
- **`server_control.sh` screen-mode log scraping:** the weakest Bash in the update area, but it is the fallback for hosts without RCON.
- **Duplicated rules inside Bash:** "what is a valid backup archive" is defined three times (`prune-chunks.js` suffix/size/age, `archive_restore.sh`, `cleanup_backups.sh`), and "newest backup" is chosen by filename timestamp in `cleanup_backups.sh` but by mtime in `restore.sh` and `rollback.sh`.
- **Well-built Bash, no change suggested:** `cleanup_backups.sh` (tiered retention, one `zstd -d | tar -tvf -` pipeline that deserves `pipefail`), `webhook.sh` (jq-built payloads, curl key on stdin), `install_jabba.sh` (pinned URL plus SHA-256).

---

## 7. Cross-Cutting Observations

### 7.1 Rule duplication across languages (the tension named in the brief)

| Rule | Copies | Status |
|---|---|---|
| Operation lock | `utils.sh`, `opLock.js`, `prune-chunks.js` re-exec | already diverged (EPERM, wait) |
| `variables.txt` escaping | 2 JS writers (+ a third scheme for `curseforge.txt`), 1 JS parser, Bash `source`, `sed` readers | one rule in three places |
| SERVICE_USER regex | `loadVariables.js`, `create_api_server_service.js`, `service_user.sh` | 3 copies |
| API-key placeholder and 32-char minimum | `loadVariables.js`, Bash preflight | 2 copies |
| Webhook events and payload | `loadVariables.js`, `webhook.sh`, `update-server.js`, README | guarded by `webhookEvents.test.cjs` |
| Mod version selection | `lib/versions.js` (becomes 2 if BC-010 moves) | 1 today |
| Mojang manifest and Java requirement | `update-server.js`, `download_utils.js` | Node-to-Node duplicate |
| Jabba pin and JDK sort | `install_jabba.sh`, `update-server.js`, `install_java.js` | 3 copies, two sort rules |
| MC version regex | `update-server.js`, `upgrade-server.js`, wrapper `MC_VERSION_RE` | 3 copies, differing lengths |

**With a Bash wizard:** every question the wizard asks has a rule (shape, range, environment) that `loadVariables.js` also checks. Each Bash check would be a second copy unless the manifest reuses the Node validator for the final result and limits the wizard to what it asks. Moving any shared rule to Bash removes a copy only if the Node copy is deleted at the same time.

### 7.2 `jq` as an accepted dependency

Facts (verified from package indexes and image manifests): `jq` is Priority optional on Debian and Ubuntu; it is present on the Ubuntu 24.04 server ISO and server cloud image, **absent from the 24.04 minimal image and from all three 22.04 images**; versions are 1.6 on Debian 12 and Ubuntu 22.04, 1.7.1 on Debian 13 and Ubuntu 24.04 (no release ships 1.8). Differences that matter: `pick` is 1.7+; numbers: 1.6 has no literal preservation, so a 64-bit integer such as a world seed can be corrupted by passing through jq, while 1.7 preserves it unless it is modified; `--arg` always binds a string; there is no in-place flag; JSONC and trailing commas are rejected, and parse errors read `jq: parse error: <message> at line L, column C` without the file name. Today jq is used for real only in `webhook.sh`; `validate.sh`, `doctor.sh` and the preflight merely check it exists, and no jq call reads `variables.json` anywhere. Making jq an accepted dependency is cheap (about 110 KiB installed, one apt line already in `download_packages.sh`) but it has to be installed before any code that uses it, and a wizard that writes JSON through jq makes it mandatory early.

### 7.3 Dependency and prerequisite story under Bash-first

- **Node versions:** no distro repo ships a currently supported line. Debian 12 ships 18.20.4, Debian 13 ships 20.19.2, Ubuntu 22.04 ships 12.22.9 and Ubuntu 24.04 ships 18.19.1 (the last two from universe); upstream EOL is 2025-04-30 for 18 and 2026-04-30 for 20. `nodejs` and `npm` are in no Ubuntu image by default. The code requires 18+ and checks nothing. NodeSource (third party) installs with a `curl | sudo bash` setup script that adds `deb.nodesource.com` with a pin over the distro package and supports amd64 and arm64 only; nvm installs per user with `curl | bash` and edits shell profiles, so a non-interactive script must source it first.
- **Bash-first does not remove Node:** the wrapper, RCON mode, the update tools and the pruner stay Node, so the prerequisite list shrinks only at the margin (`semver`), and the bootstrap still has to get a supported Node onto a bare machine.
- **Other tool facts that bear on Bash growth (verified):** `unzip` and `acl` (setfacl) are on no Ubuntu image; `whiptail`, `cron`, `screen`, `rsync` and `ufw` are missing from the Ubuntu minimal image; mawk is the default awk on all four releases (gawk is optional); Bash is 5.1 or 5.2 everywhere, so every feature at or above 4.3 (`declare -A`, `mapfile`, `${v,,}`, `wait -n`, namerefs) is available, but `mapfile -d` and `inherit_errexit` (4.4) are not at the project's stated floor.

### 7.4 Testing

The Bash harness is as strong as the Node one on failure injection and weaker on data: `jq` is a shim returning `{"shim":true}`, so a move of JSON logic to jq needs either real jq in the test environment (CI already apt-installs it) or a different strategy. CI has no Ubuntu minimal, no Node 18 and no Bash 4.3, which are exactly the environments a Bash-first, "installs what is missing" bootstrap targets, and no test runs the setup on a host without Node. Moving tested Node to Bash loses `node --test` coverage; moving Bash to Node loses shim-based failure injection.

### 7.5 Boundaries that make moves bigger than the file

Any change to how a Node mod script is invoked touches the wrapper repo (`interpreter("node")`, hard-coded `.js` paths, a capability probe by path), the sudoers rules in `service_user.sh` and `docs/sudoers-setup.md`, and `tests/shell/test_service_user.sh`. A move that renames or re-interprets a script is a cross-repo change.

### 7.6 Bug-class findings from this read (not migrations)

- The pre-install Node ordering (BC-001).
- `setup.sh:457-458` prints "undefined" for a missing CurseForge key, so `--check` reports it as configured.
- `run_or_echo` evaluates a string built from `$SCRIPT_DIR` (`logging.sh:12`).
- The `check_updates.sh` format drift (R1).

---

## 8. Open Questions

1. **Does the early-read failure reproduce on a bare image?** Test: run `main.sh` in a clean Ubuntu 24.04 minimal container or VM without Node and read the message. (Verified from code; not run.)
2. **Which Node install route fits the audience** (distro package, NodeSource, nvm, or a pinned upstream binary), and does Debian 13 appear in NodeSource's supported list (its docs table is stale)? Settle by reading NodeSource's current support statement and trying the route on each target.
3. **Does jq 1.6 corrupt a real seed or other large integer in `variables.json`?** Test with a 64-bit value through jq 1.6 and 1.7.1. The config stores the seed as a string by default, so exposure may be nil.
4. **Does `sort -V` order the Jabba candidates the same as `semver.coerce`** for the strings Jabba actually lists? Test with the output of `jabba ls-remote`.
5. **Does the Modrinth API behave the same for axios' `game_versions[]` as for the documented JSON-array form?** (Inferred difference; a move of `check-updates` would fix it if it matters.)
6. **Is `check_updates.sh` still used by anyone?** Settle by asking the maintainer and grepping deployed installs; no caller was found.
7. **Does any installed base still have legacy string entries** in `downloaded_versions.json` (the `--migrate` path in `update-mods.js` could be deleted otherwise)?
8. **What lock wait behaviour should the mod scripts have** (the 60 s wait or an immediate "busy")? A product decision that affects BC-002.
9. **Unread areas:** `migrate.sh`, `migrate-lib/plan*.sh`, `server_migrations.sh`, `vanilla/start.sh` (body), the wrapper repo beyond grep hits, most test bodies, and the full world code (judged by headers and the benchmark document).
10. **Debian cloud/netinst package membership** (jq, curl, whiptail) is unknown; Debian publishes no manifest. Settle by inspecting a booted image.
