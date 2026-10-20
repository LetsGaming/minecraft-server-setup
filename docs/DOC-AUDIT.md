# Documentation audit: minecraft-server-setup, minecraft-server-api and minecraft-bot

Date: 2026-10-20. Default conflict rule: code wins for descriptive docs; safety, contract and security statements are flagged instead of silently rewritten. No source code, tests, config or CHANGELOG files were modified. Nothing was committed.

## 1. Executive Summary

Both repos have documentation that is largely accurate. Security, auth, limits, sudoers rules, backup/restore, chunk pruning, the webhook event table, `manage.sh doctor` and the migrate-lib module map all match the code. Drift is concentrated in a few places:

- **Setup README** was stale: it listed a wrapper script at the wrong path, omitted all setup flags (`--y` also accepts the EULA), and omitted real prerequisites (`jq` for webhooks).
- **API README** listed 40 of 56 routes.
- **Reverse-proxy docs** told operators to set `MC_TRUST_PROXY=true` but the nginx example never set `X-Forwarded-For`, which is the header the wrapper trusts. Without it every client shares the proxy's IP, so one attacker's failed keys lock out everyone.
- **`variables.example.txt`** in the API repo says an empty API key disables authentication. The wrapper actually refuses to start.

Where code deviates from evident intent (two items), the docs now describe actual behavior and the question is left open (section 5).

`minecraft-bot` was audited in a second pass, after its in-progress work landed (section 3b). It had the most drift of the three: removed features (`/say`, `/playerhead`, `/netherportal`, local mode, RCON) and the move from JSON files to SQLite were still documented, and the Docker docs described config seeding wrongly.

## 2. Scope and Method

- Compared: bot README, `docs/**`, `CLAUDE.md`, Docker files and config template against `src/`, `scripts/`, `package.json`. Setup `readme.md`, all 11 `docs/*.md` against `main.sh`, `main-vanilla.sh`, `migrate.sh`, `migrate-lib/`, `src/`. API `README.md`, `openapi.json`, `docs/`, example configs against `src/`, `package.json`, `ecosystem.config.cjs`.
- Method: Sonnet subagents (one each for setup and API; two for the bot, split user/admin vs dev docs) inventoried claims and read the code; the parent re-verified cross-repo items (below) with targeted greps. Link and anchor targets checked by inspection. The API route set was compared programmatically between `openapi.json` and the README table.
- Run: read-only greps and reads. No tests, builds, installs or `openapi:check`.
- Parent spot-checks (verified): `KillMode=process` is set in the generated unit (`create_api_server_service.js`); `api-server-release.json` has `repository`, `version` (4.3.0), `sha256`; setup enforces the 32-character key minimum (`loadVariables.js`, `setup.sh`); API package name is `mc-api-server`; wrapper reads `X-Forwarded-For` only (`trustProxy.ts`, `app.ts`); `jq` is absent from `download_packages.sh`; `[[ -v ARG_OPTS["$1"] ]]` exists at `src/common/args.sh:38`.

## 3. Findings

IDs: S = setup, A = API, X = parent cross-repo. "Fixed" means a doc was edited.

### High

**[HIGH] DOC-S-001: README lists the wrapper under `scripts/<instance>/` (Incorrect). Fixed**
- Doc: `readme.md` Usage > Runtime Scripts. Code: `src/setup/structure/copy_scripts.sh`; `src/setup/management/create_api_server_service.js` (`<BASE_DIR>/services/api-server`).
- Actual: wrapper lives in `<target>/services/api-server/`. `upgrade.sh` and `world/prune-chunks.js` are deployed but were undocumented.
- Code follows docs? No. Should it? No. Resolution: row removed, rows added. Confidence: verified.

**[HIGH] DOC-X-001: nginx example omits `X-Forwarded-For` while docs require `MC_TRUST_PROXY=true` (Incorrect). Fixed**
- Doc: `docs/reverse-proxy.md` (nginx block sets only `X-Real-IP`, advice sets `MC_TRUST_PROXY=true`). Code (api repo): `src/config/trustProxy.ts`, `src/http/app.ts`; `README.md` Security explains the lockout consequence.
- Actual: the wrapper trusts only `X-Forwarded-For`. Without it all clients appear as the proxy IP: shared rate limits and a shared auth-failure lockout.
- Code follows docs? n/a. Should it? Code is correct. Resolution: added `proxy_set_header X-Forwarded-For $remote_addr;` (set, not appended, matching the API README's rule). Confidence: strongly supported (read from code and README; not run behind nginx).

### Medium

- **DOC-S-002** `jq` is required for webhooks but neither installed, checked by `--check`, nor documented (Missing, possible code defect). Doc: `readme.md` Prerequisites. Code: `src/scripts/common/webhook.sh`, `src/setup/download/download_packages.sh`. Webhooks silently do nothing without `jq`. README now lists the real package set and says `jq` is an operator prerequisite. See OQ-1. Verified. Fixed (docs).
- **DOC-S-003** `docs/migrations.md` `unit_start_limits` row wrong (Drifted). Code (`migrate-lib/server_migrations.sh`) writes the lines to `[Unit]` and moves any found in `[Service]`; docs said "after RestartSec". The code header comment carries the same stale wording (OQ-4). Verified. Fixed (doc).
- **DOC-S-004** README omitted all setup flags; `--y` also sets `EULA=true` (Missing). Code: `main.sh` `ARG_OPTS`, `src/common/flags.sh`. Options table added. Verified. Fixed.
- **DOC-S-005** README said the wrapper "will prompt" (Incorrect, code deviates from intent). With `API_SERVER.ENABLED: true` the wrapper is deployed even if the prompt is answered "no" (`src/common/setup.sh` ~159-172). Docs now describe actual behavior; not presented as intended contract. See OQ-2. Verified. Fixed (wording).
- **DOC-A-001** API README route table listed 40 of 56 routes (Missing). 16 rows added (`/metrics`, `/events`, upgrade/prune operations, ten `prune/*` routes). No orphaned documented route. Verified (set comparison; handler schemas not diffed). Fixed.
- **DOC-A-002** `variables.example.txt` says an empty `API_SERVER_KEY` disables auth (Incorrect). Code: `src/index.ts`, `src/http/auth.ts`: wrapper exits unless `MC_ALLOW_NO_AUTH=true`, which also forces loopback binding. Fails closed, but following the comment gives a crash loop. Code is correct. Not fixed (example config, outside agreed edit set). Verified.

### Low

- **DOC-S-006** Several docs not linked from README; `manage.sh update/start/stop` undocumented (Missing). Fixed.
- **DOC-S-007** Config constraints undocumented: `RESTART_SCHEDULE` limits, `SERVICE_USER`, install layout, first run creates `variables.json` then exits (Missing). Fixed.
- **DOC-S-008** `docs/migrations.md` omitted `--y`, `--restart`, `--no-stop`, `--no-service-restart` and the instance layout move (Missing). Fixed. Ordering text left as a simplification.
- **DOC-S-009** `docs/upgrade.md` omitted `--countdown`, `--start-timeout`, `--prune-plan`, `--prune-only`; operation-lock participants list incomplete (stop, restart, maintenance, cleanup, prune and mod scripts also take the lock) (Missing/Drifted). Fixed.
- **DOC-S-010** `docs/retiring-web-interface.md` referenced sudoers patterns that no longer exist (Drifted). Fixed.
- **DOC-S-011** `docs/reverse-proxy.md` redirect vhost used a different host than the API vhost (Drifted). Strongly supported. Fixed.
- **DOC-S-012** `docs/wrapper-release.md` examples used stale 4.1.0 (pin is 4.3.0); now `x.y.z` (Drifted). Fixed.
- **DOC-S-013** Bash floor documented as 4.0+, probably 4.3+ (`src/common/args.sh:38`) (Ambiguous). Not edited; could not test an older bash. Assumption-dependent. See OQ-3.
- **DOC-S-014** `src/setup/download/readme.md` stale (Node 12, wrong paths, nonexistent invocation) (Drifted). Outside edit scope. Verified. See OQ-5.
- **DOC-X-002** Wrapper called `minecraft-api-server` in `reverse-proxy.md` and `secrets-management.md`, but the package is `mc-api-server` (Drifted). Fixed in both; the systemd unit is `<install>-api-server`.
- **DOC-A-003** `variables.example.txt` marks `INSTANCE_NAME` required; it defaults to `server`, and PM2 naming reads only the env var (Drifted). Not fixed (example config).
- **DOC-A-004** `.env.example` implies `.env` is loaded; nothing in the project reads it (Ambiguous). Not fixed. See OQ-6.
- **DOC-A-005** Body-limit exceptions understated (upgrade 64 KB, prune 512 KB). Fixed.
- **DOC-A-006** Rate-limit text: 100/min applies to all methods before auth, `/metrics` exempt, writes add a 10/min budget after auth. Fixed.
- **DOC-A-007** API key rules undocumented (no leading/trailing whitespace, at least 8 distinct characters). Fixed.
- **DOC-A-008** `MC_LOG_DIR` undocumented. README fixed; `.env.example` not.
- **DOC-A-009** "Error bodies are always `{ error }`" omits `busy` on 423. README fixed; `openapi.json` is generated (`src/contracts/openapi.ts`), fix at the source. See OQ-7.

### Informational

- **DOC-S-015** "Upgrading to 4.0" is historical (package is 5.0.0); `start.sh --validate` and `main.sh --check` check different tool sets. No fix needed.
- **DOC-A-010** `docs/sudoers-setup.md` wording ("three more shapes" followed by five; `du` also used). Fixed. All sudo command shapes match code.
- **DOC-A-011** `MC_ALLOW_NO_AUTH` only matters when no key is set; docs describe that case. Safe as written.

Counts for setup and API: High 2, Medium 6, Low 17, Informational 3 (28). With minecraft-bot (50 findings: High 9, Medium 18, Low 23): High 11, Medium 24, Low 40, Informational 3 (78 total). Possible code deviations from intent: DOC-S-002, DOC-S-005, DOC-B-003, DOC-B-011.

## 3b. minecraft-bot findings (v8.1.0)

Two agents split the repo: user/admin/root docs (28 findings: 9 High, 11 Medium, 8 Low) and `docs/dev/**` plus `CLAUDE.md` (22 findings: 7 Medium, 15 Low). 44 of the 50 were fixed in docs. The full per-finding detail (doc location, code location, actual vs documented, confidence) is in the two agent reports; the grouped summary is below. IDs: B = user/admin, D = dev.

### High (all fixed in docs unless noted)

- **DOC-B-001** `/say`, `/playerhead`, `/netherportal` slash commands are documented in six files but were removed (commit 679d331). Only `!playerhead` and `!netherportal` remain, and they need no linked account. Code: no such builders under `src/bot/commands`; in-game forms under `src/bot/logWatcher/commands`.
- **DOC-B-002** `docs/admin/docker.md` says the config is regenerated from the template on every start. `docker-entrypoint.sh` seeds it once; later `.env` edits do nothing until the copy is removed.
- **DOC-B-003** The documented Docker template path plus `--profile web` makes the web container exit: `config.template.json` has no `webui` block and `src/web/backend/index.ts` exits unless `webui.enabled === true`. Docs fixed; template not (OQ-B1).
- **DOC-B-004** Status embed documented as on by default; code requires `statusEmbed.enabled === true` (opt-in).
- **DOC-B-005** Daily-reward docs say the player must be online; code queues offline claims (cap 3, `dailyClaim.ts`, `dailyStore.ts`).
- **DOC-B-006** Docs name per-feature JSON files (`linkedAccounts.json`, `claimedDaily.json`, audit JSONs, ...) for state that now lives in SQLite (`data/bot.db`; `src/core/db/migrations.ts`, `importLegacy.ts`). The "no way to query the audit trail" statement was also stale.
- **DOC-B-007** `commands.<name>.url` documented; the real key is `commands.<name>.options.url` (schema has `additionalProperties: false`).
- **DOC-B-008** Emergency-access runbook commands fail: `jq .lines[]` (wrapper returns `{ output }`), `API_KEY` (wrapper variable is `MC_API_KEY`), dashboard port 8080 (default 8130). Cross-repo, verified against the wrapper's `openapi.json` and README. A further wrong default (wrapper bind `127.0.0.1:3000` vs real `0.0.0.0:3000`) was fixed by the parent.
- **DOC-B-009** Wizard-to-Docker path in `setup.md` and README omits `MCBOT_CONFIG_FILE=./config.json`; without it the wizard output is ignored and a template config with blank secrets is seeded. `scripts/setup.mjs` still prints a stale hint (OQ-B2).

### Medium

- **DOC-B-010** `configuration.md` ("full reference") omitted real keys (`publicAddress`, `modpack`, ping settings, `timezone`, leaderboard post time/day, `featureNudges`, `webui.clientId`, the 8.1.0 empty-`allowedServers` rule). Fixed.
- **DOC-B-011** `.env.example`, compose comments and `config.template.json` mention removed behavior (`RCON_PASSWORD` overrides, a `commands.say` entry). Not fixed (config files). OQ-B5.
- **DOC-B-012..020** Node 18+ should be 20+; dashboard pages table missed Upgrade, Prune and Appearance; `remote-setup.md` still described local instances; three broken anchors; pagination timeout 60 s vs 3 min; slash rate limit does have a config knob (`limits.slashCapacity`); leaderboard stats list incomplete (5 of 12); stale wrapper version numbers (`MIN_WRAPPER_VERSION` is a 3.0.0 pre-manifest fallback). All fixed. DOC-B-019 (`host.docker.internal` does not resolve on Linux without `extra_hosts`) is not fixed (OQ-B4).
- **DOC-D-001..007** Contributor docs: leaderboard-stat recipe now needs `defineStat` plus locale keys in both locales; `core/readme.md` layout lists nonexistent directories; coding rule 6 names a nonexistent helper; startup/shutdown sequence stale; `data-storage.md` omits tables and lists removed caches; `config.md` has the wrong load pipeline (actual: migrate, env overrides, validate, freeze) and wrong secret-key list (`SECRET_SERVER_KEYS` in `src/schema/config.ts`, includes `rconPassword`); `decisions.md` keeps pre-5.0 decisions with no supersession note (DOC-D-007, not edited, OQ-B3).

### Low

DOC-B-021..028 and DOC-D-008..022: snapshot retention 32 days (not 31), stale ROADMAP version, index and wording fixes, a `jq` expression error in `retiring-server-manager.md`, `/health` response shape, stale RCON mentions in contributor docs, wrong file paths and nonexistent symbols (`paginateLines`, `DEFAULT_GET_TIMEOUT_MS`), `testing.md` directory table, wrong tsconfig named, `CLAUDE.md` path and test-layout errors. Two not fixed: DOC-D-022 (`frontend.md` source tree incomplete) and DOC-B-028 (permissions wording; example port 3030 vs default 3000).

### Verified accurate

Slash and in-game command inventories, options and cooldowns; admin gating; all 14 dashboard capabilities; env vars (no documented variable missing from code); compose, healthchecks, entrypoint ordering; rate-limit and timing numbers; migration guides 5/7/8; npm scripts; ESLint boundary rules and CI gates; wire-contract claims against the wrapper (no mismatches); `docs/features.md` (no drift); history docs are clearly labelled historical.

## 4. Missing Documentation

- Operators (setup): a short "Requirements and preflight" section stating exactly which tools `--check` verifies and which it does not (blocked on OQ-1).
- Contributors (setup): replace or delete `src/setup/download/readme.md`.
- API consumers: once the generator text is adjusted (OQ-7), `openapi.json` should state the 423 `busy` field.
- Bot operators: nothing new; the Docker config-seeding and wizard-to-Docker paths are now documented but depend on OQ-B1 and OQ-B2.

## 5. Open Questions for Maintainers

- **OQ-1** Should setup install `jq` and should `--check` verify `jq`, `unzip`, `cron`, `setfacl`? (a) Yes (recommended: webhooks fail silently); (b) keep as operator prerequisite (current docs).
- **OQ-2** With `API_SERVER.ENABLED: true`, should "no" at the prompt skip the wrapper? (a) honor the answer; (b) skip the prompt when enabled (recommended); (c) keep and document (done).
- **OQ-3** Supported Bash floor: change README to 4.3+ or add a version guard?
- **OQ-4** Update the stale "after RestartSec" comment in `migrate-lib/server_migrations.sh` (lines ~90-97). Code change, separate task.
- **OQ-5** Rewrite or delete `src/setup/download/readme.md`?
- **OQ-6** Is `.env` meant to be auto-loaded? (a) document `EnvironmentFile=` / `node --env-file` (recommended); (b) add loading; (c) delete the file.
- **OQ-7** Adjust the generator text in `src/contracts/openapi.ts` to mention `busy` on 423, then `npm run openapi:generate`?
- **OQ-8** May auditors edit comment text in `variables.example.txt` and `.env.example`? Recommend yes; that would close DOC-A-002/003/004/008.
- **OQ-9** The no-key fatal message in `src/index.ts` suggests the `API_SERVER_KEY` env var, which only works in variables.txt/env mode, not with `api-server-config.json`. Intent unclear.
- **OQ-10** `/health?x=1` is treated as authenticated and rate limited because of an exact URL match. Intended?

- **OQ-B1** Should `config.template.json` ship `"webui": { "enabled": true }`? (a) yes, so `--profile web` works out of the box (recommended; compose, `.env.example` and README present it as a one-flag opt-in); (b) keep the template and the new doc warning.
- **OQ-B2** Update the stale Docker hints printed by `scripts/setup.mjs` (predate `MCBOT_CONFIG_FILE`)? Recommended yes.
- **OQ-B3** `docs/dev/decisions.md`: annotate pre-5.0 entries (RconClient, local/remote seam, log read cap) as superseded (recommended) or leave as history? Also: drop the "B-xx fix ID" sentences in `coding-guidelines.md` and `testing.md` (no such annotations exist); is the "clean-code wave" precondition in `cross-server-relay.md` obsolete?
- **OQ-B4** Add `extra_hosts: ["host.docker.internal:host-gateway"]` to the `bot` compose service (recommended), or add a Linux caveat to `docker.md`.
- **OQ-B5** Remove dead `RCON_PASSWORD` lines from `.env.example` and compose comments, and the `say` entry from `config.template.json`? Recommended yes.
- **OQ-B6** Rename `docs/readme.md` to `README.md` (recommended; `CLAUDE.md` links `docs/README.md`, which breaks on case-sensitive filesystems) or fix the references.
- **OQ-B7** The removal of `/say`, `/playerhead`, `/netherportal` has no CHANGELOG entry. Add a retroactive note?

### Decisions and follow-up (2026-10-20)

The maintainer answered every question above. Status:

- **Implemented (uncommitted), setup:** OQ-1 (`jq` installed, `--check` verifies `jq unzip cron setfacl`), OQ-2 (prompt skipped when `API_SERVER.ENABLED` is true), OQ-3 (Bash 4.3+ in README), OQ-4 (migration comment), OQ-5 (download readme rewritten). New tests: `tests/shell/test_setup_flags.sh` (15 assertions pass); `test_setup_rollback.sh`, `test_server_migrations.sh`, `test_migrate_modules.sh` pass. Not run: full shell suite, shellcheck (not installed), real Linux/apt.
- **Implemented (uncommitted), API:** OQ-6, OQ-7 (`openapi.json` regenerated, `openapi:check` passes), OQ-8, OQ-9 (mode-aware fatal message), OQ-10 (`/health` matched by pathname). Typecheck, lint and tests pass except 4 symlink tests that fail with `EPERM` on this Windows box (`tests/platform/stateDir.test.ts`, `tests/instances/configSafety.test.ts`); not run on Linux.
- **Implemented, bot (docs only):** OQ-B3 (three superseded entries in `docs/dev/decisions.md`, B-xx and "clean-code wave" sentences removed), OQ-B6 (docs/readme.md renamed to docs/README.md; link check over 56 files clean).
- **Deferred by instruction (bot, outside `docs/`):** OQ-B1 (template `webui` block, decided: `enabled: true`), OQ-B2 (`scripts/setup.mjs` hints), OQ-B4 (compose `extra_hosts`), OQ-B5 (dead `RCON_PASSWORD` lines and `say` entry). Also root `README.md` line 88 still links `docs/readme.md` and needs updating to `docs/README.md`.
- **Declined:** OQ-B7 (no retroactive CHANGELOG entry).
- Changelog entries were added to the setup and API `CHANGELOG.md` files under Unreleased.

## 6. Changes Made (uncommitted, docs only)

minecraft-server-setup:
- `readme.md`: prerequisites and `jq`, install layout, first-run behavior, `RESTART_SCHEDULE`/`SERVICE_USER`, setup options table, wrapper wording, runtime script table, `manage.sh` commands, documentation index.
- `docs/migrations.md`, `docs/upgrade.md`, `docs/retiring-web-interface.md`, `docs/wrapper-release.md`: as listed in findings.
- `docs/reverse-proxy.md`: vhost name, `X-Forwarded-For` header, wrapper name.
- `docs/secrets-management.md`: wrapper heading renamed.
- `docs/DOC-AUDIT.md`: this report (new, untracked).

minecraft-bot (uncommitted; `CHANGELOG.md` and `config.schema.json` untouched):
- `README.md`, `CLAUDE.md` (two factual path/layout errors), `docs/ROADMAP.md`, `docs/readme.md`.
- `docs/admin/`: automated-features, configuration, daily-rewards, dashboard, docker, emergency-access, migrating-to-5, permissions, remote-setup, retiring-server-manager, setup, troubleshooting.
- `docs/user/`: chat-bridge, commands, daily-rewards, getting-started, linking, stats-and-leaderboards.
- `docs/dev/`: architecture, coding-guidelines, contracts, testing, wave2-summary, and bot/, core/, web/ pages as listed in DOC-D findings.

minecraft-server-api:
- `README.md`: 16 routes, body limits, rate limits, key rules, `MC_LOG_DIR`, 423 `busy`.
- `docs/sudoers-setup.md`: wording and `du`.

Every edit was checked against the cited code. Commands and examples were not executed.

## 7. Coverage and Limitations

- Bot, not verified in depth: dashboard UI behavior text (prune map and terrain limits), `mod-configs.md` limits and `mods-version-check.md` timings (wrapper behavior), `server-upgrade.md` steps, `chunk-pruning.md` beyond its intro, `config.schema.json` consistency (`schema:check` not run). Per-finding detail for the bot lives in the two agent reports in the session scratchpad (`audit-bot-user.md`, `audit-bot-dev.md`), which are temporary and not saved in the repo.
- Bot docs have net-zero em dash change, but pre-existing em dashes remain in several files.

- Compared well: setup README and all docs except the partial items below; API README, security statements, sudoers, route set.
- Partially: chunk-pruning internals, prune-benchmarks numbers (not re-measured), `upgrade.md` later steps, `secrets-management.md` (repo-side claims only), per-route request/response schemas in `openapi.json`.
- Not at all: behavior needing a Linux host (systemd, sudo, ACLs); CHANGELOG files; runtime behavior of nginx plus the wrapper.
- No checks beyond reads and greps. Absence of a finding is not proof of accuracy.
- Still-unchecked cross-repo items: `GET /manifest` feature list and the "wrapper 3.3.0 or newer" claim in `retiring-web-interface.md` vs the 4.3.0 pin; bot config keys and env vars; default port 3000/RCON 25575 parity; the release workflow's edit of `api-server-release.json`.

## 8. Conclusion

Priorities: decide the bot template question (OQ-B1, dashboard container exits out of the box), OQ-1 and OQ-2 (silent webhook failure, ignored prompt answer), fix the API example config comments (OQ-8). Review and commit the doc edits in all three repos; nothing is committed.
