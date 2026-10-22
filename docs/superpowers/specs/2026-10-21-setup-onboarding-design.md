# Setup onboarding: design

Status: draft for approval (builder check done; section 13 lists the calls made after it). Date: 2026-10-21.
Inputs: `docs/research/setup-onboarding-ux.md`, `docs/research/node-to-bash-candidates.md`, `docs/research/mirror-servers-multiworld.md` (Appendix A on c2me), and the decisions below.

Marking: **Decided** = said by the maintainer. **My call** = a choice made for the builder, listed again in section 11 so it can be checked and changed.

---

## 1. Intent and why

A non-IT person with a fresh Ubuntu or Debian machine should get from `git clone` to a running Minecraft world with backups, service and restart tooling already set up, by running **one command**. Today the path needs a hand-edited strict JSON file, an `npm install` before the tool can run, knowledge of Java heap sizes, and a first run that creates the config and exits with an error. A previous review rated that path 3/10 for non-IT users and 8/10 for admins.

The same change must not slow down admins who know what they are doing.

## 2. Goals

1. One command after cloning produces a running, backed-up server.
2. Three routes, chosen by situation (section 4): **Default**, **Guided**, **Power-user**.
3. The Default route is safe: it cannot be made to break the machine or an existing install by choices the user does not understand (RAM, ports, existing worlds).
4. Whenever the tool changes a value for safety, it says so loudly and visibly, and the user can still carry on.
5. The tool installs everything that is necessary and **only** what is necessary.
6. The wizard is modular: adding a new setting means adding a data entry, not writing a new screen or re-implementing checks.
7. Bash-first: Bash for orchestration, detection, the wizard and config generation; Node only where it is clearly better (section 8).
8. Servers shipped by default only contain mods that are server-only or client-optional, so friends can join with a plain client.
9. The user is told, in plain words, that reaching the server from outside the home network needs an open router port and a port forward, and which port.

## 3. Non-goals and anti-goals

**Non-goals**
- Opening or configuring the router. The tool cannot and should not do it.
- A GUI, web UI or Docker. Terminal only.
- Windows or macOS as a host. The suite is Debian/Ubuntu with systemd, cron and apt.
- Mirror servers and multi-world support (deferred to a later project).
- Moving more Node code to Bash than this project needs. The migration candidates BC-002 to BC-019 in `docs/research/node-to-bash-candidates.md` are out of scope unless a section below names them.
- Changing the existing `variables.json` format or the admin flags.

**Anti-goals (a failure even if it technically works)**
- A wizard that can overwrite or damage an existing instance or world.
- A silent correction: any automatic change of a user-visible value that is not announced.
- A second copy of a validation rule that can drift from the first.
- Slower or more interactive behaviour for an admin who supplies a config and flags.
- Installing packages that the chosen options do not need.

## 4. The three routes

| Route | For | Behaviour |
|---|---|---|
| **Default** | Anyone who just wants a server | Almost no questions. Detects the machine, applies safe defaults, prints a summary of everything it will do and everything it corrected, asks for confirmation (and EULA acceptance), then installs. |
| **Guided** | Someone who wants to choose | A whiptail wizard with Back and Cancel, plain-language explanations per step, safe values prefilled, the same loud corrections. Covers choices Default does not make (server type, version, name, RAM, vanilla or modpack, backups, restart schedule, webhook, API wrapper). |
| **Power-user** | Admins and automation | Unchanged: an existing `variables.json` plus today's flags (`--check`, `--dry-run`, `--y`, `--vanilla`, `--api-server`, and so on). No wizard, no extra prompts. With no config and no TTY it keeps today's behaviour (creates the file from the example and exits with instructions); `--default --agree-eula` runs Default non-interactively. |

**Route selection (my call).** Power-user when `variables.json` already exists or when stdin is not a TTY; otherwise the user chooses between Default and Guided in a first screen, with Default preselected. Explicit flags `--default` and `--guided` override. The Default and Guided routes both end by writing a `variables.json` (through the same manifest, section 6) so the choices become the Power-user route on the next run.

## 5. The one command and the bootstrap

`bash main.sh` stays the entry point (my call: keep the name; `npm run setup` keeps working). It must run on a machine that has only Bash, sudo, coreutils, apt and network access.

**Stage order (Decided: install everything necessary, only what is necessary).**
1. Bash-only checks: not root, `sudo` works (existing), Debian/Ubuntu with apt, systemd present. Fail with a clear message otherwise.
2. **Prerequisite stage.** Detect what is already there; install only what the chosen route and options need. Always needed for the server: `curl`, `jq`, `screen`, `unzip`, `cron`, `rsync`, `zstd`, `acl`, Node of an acceptable version (the install uses Node for API and download work; `npm ci --omit=dev`). Needed only for some options: `whiptail` (Guided route only), `ufw`-related nothing, `openssl` only if a key is generated. No system upgrade (the existing `MC_SETUP_UPGRADE_SYSTEM` opt-in stays).
3. Route selection and the wizard (Default or Guided) or the existing flags path (Power-user).
4. Config written, then validated by `loadVariables.js` (section 8) before anything is installed.
5. The existing install pipeline runs (`run_setup_startup` onwards), with its rollback trap.
6. Final screen: where the server is, how to join locally, the port, the networking notice (section 9), and where backups and the service live.

**Fix for the current ordering bug.** Today `resolve_instance_vars` (`src/common/setup.sh:123`), `snapshot_setup_state` (`:209`) and `api_server_enabled_in_config` (`src/common/flags.sh:16`) call `node` before `download_packages.sh` has installed it, and hide the real error with `2>/dev/null`. After this change no `node` call happens before the prerequisite stage has made Node available, and a missing or too-old Node produces an explicit message.

**Node version policy (my call).** The code requires Node 18 or newer and checks nothing today. No Debian/Ubuntu repository ships a currently supported line (Debian 12: 18; Debian 13: 20; Ubuntu 24.04: 18; Ubuntu 22.04: 12; all past upstream end of life); options and trade-offs are in `docs/research/node-to-bash-candidates.md` section 7.3. Policy:
1. Accept any installed `node` at version 18 or newer; add the missing version check (`node -v`) with a clear message.
2. If Node is missing or older than 18, and the distribution's own `nodejs` package is 18 or newer (Debian 12/13, Ubuntu 24.04), install that package: no third-party trust, minimal change.
3. Otherwise (Ubuntu 22.04, Debian 11, or any release whose package is older than 18), install Node 22 from the NodeSource apt repository (22 is the line CI already tests). This is a third-party repository and is shown in the summary as a separate, named action that the existing confirmation covers. Power-user and non-interactive runs do not add it silently: they stop with a message and the exact command, unless `--allow-nodesource` is given.
4. Node is installed with its `npm` as one unit; nvm and pinned binaries are not used.

## 6. Wizard architecture (whiptail, modular)

**Decided:** whiptail; modular from the start; clean-code conventions; no re-implementation of checks per feature.

Layout (my call): `src/wizard/` with single-purpose files, in the same style as `migrate-lib/` and `src/common/`:

| Part | Responsibility |
|---|---|
| **Step manifest** (data) | One entry per question: id, the `variables.json` key it fills, title, plain-language help text, widget type (input, yes/no, menu, radiolist, checklist, password), default (literal or a detector), the routes it appears in (Default, Guided), validators by name, and an optional `when` condition (for example "only if modpack"). |
| **Engine** | Reads the manifest, draws each step with whiptail, handles Back (Cancel at step 1 exits; Cancel later goes back), collects answers into a map, applies the loud-correction rules, renders the summary. No step has bespoke control flow. |
| **Validator library** | Named, reusable checks: port, memory size (`4G`), integer range, instance name, directory free space, free port, and so on. Each returns a message that says what is wrong and what would work. |
| **Detector library** | Reads the machine once: available RAM (`/proc/meminfo`), disk space, CPU count, listening ports (`ss`), existing instances and systemd units, OS and release, installed prerequisites. Used for defaults and for the safety rules. |
| **Config writer** | Turns the answer map into `variables.json` using `jq` (atomic write, mode preserved, secrets never on a command line), merging over `variables.example.json` so unasked keys keep their documented defaults. |
| **UI helpers** | whiptail wrappers (output on stderr or `--output-fd`, exit codes 0/1/255, terminal-size handling), colour and plain-text warning rendering, a no-TTY check. |

Adding a setting: add a manifest entry and, if no existing validator fits, one validator. Nothing else changes.

**whiptail facts the builder must honour (verified in the research):** it has no input validation and no non-TTY fallback, exits 255 on terminal failure, needs manual sizing, and is **missing from Ubuntu's minimal cloud image**; the prerequisite stage installs it only when Guided is chosen. If whiptail cannot be installed or the terminal is unusable, fall back to the Default route with a notice (my call).

## 7. Safety rules (apply to Default and Guided)

**Decided:** the tool picks a safe value itself and is not quiet about it; the user can still proceed.

1. **Detect before deciding.** Available RAM, disk, CPU, and which ports are free are read from the system, not asked.
2. **Memory.** The heap is derived from available RAM with headroom for the OS; the user never types a raw size in Default. A value the user types in Guided that exceeds what is safe is replaced by the safe maximum and flagged. Starting rule (my call, tunable in one place): reserve the larger of 1 GB or 25% of available RAM for the OS, and give the server the rest up to a cap, with `Xms` equal to `Xmx`. If the machine is below a floor where a server cannot run acceptably (my call: about 1.5 GB usable), still proceed with the smallest working value and a red warning that says so. The pre-touch and GC flags in the example config are reconsidered for small heaps by the builder.
3. **Port.** Always try the default 25565 first and use it when free (**Decided**). If it is taken, switch to the next free port (**Decided**) and warn loudly, showing the chosen port prominently because it is what friends type and what is forwarded on the router. The same logic applies to the RCON port when RCON is on (my call).
4. **Existing installs.** If an instance, world, systemd unit or install directory for the chosen name already exists, Default and Guided never overwrite it. They show what exists and point to `manage.sh doctor` and `migrate.sh` (my call: that is the "repair or already exists" path; deeper repair behaviour is out of scope).
5. **Preflight.** The existing `--check` logic runs before any change; a failure stops with an explanation before anything is touched.
6. **Rollback stays.** The existing snapshot and rollback on failure or Ctrl-C remain in force for every route.
7. **Consent.** The Minecraft EULA is accepted by an explicit, visible step showing the Mojang URL, never as a side effect (my call). `--y` for Power-user keeps today's documented behaviour.
8. **Secrets.** Generated API keys and passwords are created by the tool where needed, written with restrictive modes, and never printed or logged.

**Loud-correction presentation (Decided):** every automatic change appears as a distinct block: coloured (yellow for adjusted, red for serious) with a text prefix (`WARNING:` or `ADJUSTED:`) so it survives terminals without colour, stating what was asked, what was chosen, and why. All corrections are repeated together on the summary screen before the user confirms. A run with corrections ends with them listed again.

## 8. Bash and Node boundary

**Decided:** Bash-first, Node only where it is clearly better.

**Bash:** the entry point, prerequisite stage, route selection, wizard and its libraries, detection, config writing (`jq`), the systemd, cron and backup setup that is already Bash, and the Xaero config patching.

**Stays in Node (research verdicts):** `loadVariables.js` as the final authority over the generated `variables.json` (BC-019: about 50 rules, tested; the wizard validates only what it asks), all Mojang/Modrinth/CurseForge/Fabric HTTP and hash-verified downloads, the world pruner, `rcon.js`, the update and upgrade tools, the API wrapper.

**In scope from the migration research:**
- **BC-001** (bootstrap order, section 5).
- **BC-006 (my call, only if cheap):** one shared `set_var`/`get_var` helper for `variables.txt` if the wizard work touches those writers; otherwise deferred.

**Out of scope here:** BC-002 to BC-005 and BC-007 to BC-018 (lock deduplication, Jabba consolidation, `semver` removal, moving the mod scripts, and so on). They may follow as separate work.

**Rule duplication guard.** A rule asked by the wizard lives in the validator library and is also enforced by `loadVariables.js`. The two must not diverge silently: a test feeds the same cases to both (builder decides the mechanism).

**jq as a dependency (Decided: install necessary things).** `jq` becomes a prerequisite installed before any code that uses it. Use only features common to jq 1.6 and 1.7 (Debian 12 and Ubuntu 22.04 ship 1.6); keep integer-like values that may exceed 53 bits (seeds) as strings; jq rejects JSON with comments, so the generated file must be strict JSON.

## 9. Networking notice

**Decided:** the tool does not touch the router, but the user is told.

On the final screen, and in the README, in plain language: friends on the same network can join with the machine's local address and the port; friends elsewhere need the router to forward that TCP port to this machine, and the machine's public address or a dynamic-DNS name. The notice shows the **actual chosen port** and the machine's local address (read from `ip route get`, my call), and a short "how do I check this" pointer. The tool does not claim to know whether the router is configured.

## 10. Server types, mods and Xaero's

**Decided:** priority is Fabric, then Vanilla, then Modpack.

- **Default route:** a Fabric server on the latest stable Minecraft release, with the Java version resolved automatically, with the **performance and utility mod groups installed** (the two groups that default to on in `variables.example.json`) and the optional group off. The pin of the Minecraft version at install time is recorded in config so later steps do not drift.
- **Guided route:** Fabric, plain Vanilla (no mods), or a CurseForge modpack. The modpack path needs a CurseForge API key and pack id (existing mechanism); it appears only in Guided. The optional mod group is offered as an opt-in checklist.
- **Principle (Decided):** every mod the suite ships is server-only or client-optional. The suite never adds XaeroPlus (the Xaero mod pages warn against it).
- **Known risk accepted with the decision to ship the defaults:** `c2me-fabric` publishes only alpha builds and the suite installs the newest alpha at setup time (`docs/research/mirror-servers-multiworld.md`, Appendix A). Nothing in this design changes that.

**Xaero's Minimap and World Map (opt-in group).** Both are mostly client-side mods; on a server they are optional and only make the server stricter about vanilla clients unless status-effect registration is switched off (Xaero's own FAQ: the "common" config under `config/xaero/` has an option that disables registration of status effects, which otherwise stops vanilla clients from joining; changes need a server restart).

**Decided values** (file paths under `instances/<name>/config/xaero/`):

| File | Key | Value |
|---|---|---|
| `lib/common.cfg` | `everyone_tracks_everyone` | `true` |
| `minimap/common.cfg` | `register_minimap_status_effects` | `false` |
| `world-map/common.cfg` | `register_status_effects` | `false` |

These key names come from the maintainer's own server files for the current mod versions (the Xaero pages do not document the option names). Only these three lines are patched; all other lines, including `allow_internet_access` and the profiles, stay as the mod wrote them. **Decided mechanism:** the mods create the files with default values; the suite adjusts the three keys in place and keeps everything else.

- **When:** whenever a Xaero mod is installed or updated by the suite, the keys are (re-)checked, because an update can add or rename options.
- **How (my call):** the files exist only after a mod has started once. The setup either starts the server once, waits for the files, patches the keys and restarts, or pre-creates a file containing only the key (whether the mods fill in missing keys is untested). The builder tests which works and uses the less intrusive one.
- **Unverified and flagged:** that these key names remain stable across Xaero versions; the Xaero mods are All Rights Reserved with no source repository.

## 11. Delivery and quality

**Decided: all implementation is delivered as waves of commits on a separate branch, with a single pull request at the end.** No direct commits to `main`. Each wave is a coherent, independently testable set of commits (Conventional Commits, no scope, lowercase imperative summary, no AI attribution lines in commits or the PR). The PR description lists the waves.

- **Tests (my call):** shell tests for the wizard engine, validators, detectors and config writer using the existing harness (`tests/shell/`), a new `whiptail` shim, and real `jq` (CI already installs it); a test that runs the entry script with `node` absent from `PATH` and asserts the new message; unit tests for the three Xaero patches; the existing 251 shell and 295 Node tests must stay green. Run tests once per wave, not per change.
- **Docs:** README gets a "Quick start" and a "What is this" at the top, the networking notice, and the three routes; fix the existing inconsistencies (port default 3000 vs 3030, the invalid comma in the JSON snippet, `jsonc` shown as valid config, and the claim that Node is installed automatically). `docs/GLOSSARY.md` gets entries for the new terms (route, step manifest, correction). `CHANGELOG.md` is updated in the repo's existing style.
- **CI gaps noted by the research (not required by this design):** no Ubuntu-minimal job, no Node 18 job, no Bash 4.3 job.

## 12. Left to the builder

Names of functions and files inside `src/wizard/`; whiptail window sizes; exact wording of help texts and warnings; the validator and detector internals; the exact heap formula within the stated rule; the choice of how the Xaero files are created (section 10); how the wizard-versus-`loadVariables.js` consistency test works; the default values of settings not named here (taken from `variables.example.json`: instance name `server`, difficulty, max players, MOTD, and so on); wave boundaries within the constraints in section 11.

## 13. Resolved calls after the builder check

These were open after an independent read of this document. The maintainer authorised autonomous resolution; each is my call and can be changed.

1. **Node source:** the policy in section 5 (distro package at 18 or newer, otherwise NodeSource 22 with explicit disclosure; `--allow-nodesource` for non-interactive runs).
2. **A failed or rolled-back install keeps `variables.json`.** The snapshot and rollback cover the install pipeline, not the config file. The failure screen says: "Your answers are saved in variables.json. Run again to retry, or delete it to start over." An existing `variables.json` always selects the Power-user route, so a retry re-validates and re-runs the preflight. Rollback must not delete `variables.json`; a test asserts it.
3. **Default route and an existing instance name:** the Default route takes the name `server`; if that instance, directory or unit already exists it uses the next free name (`server-2`, `server-3`, ...) and shows a loud correction. Guided validates a typed name against existing ones and refuses to reuse one. Nothing existing is touched (section 7.4 still holds: "never overwrite" is satisfied by choosing a different name).
4. **"Latest stable Minecraft" with the default mod groups:** the Default route resolves the newest Minecraft release for which Fabric and **every mod in the performance and utility groups** have a build (the existing `pickVersion` rule: release, then beta, then alpha). It looks back at most three releases. If the newest release lacks a build for some mod, the server uses the older version that works for all and says so loudly ("26.3 was skipped because mod X has no build"). If no version in range works for all mods, the version supported by the most mods is used and the others are excluded, loudly, through a new optional config key `JAVA.SERVER.VANILLA.MODS.EXCLUDE` (list of slugs; without it one unavailable mod fails the whole install). A new optional key `JAVA.SERVER.PORT` (default 25565) carries the chosen server port into `server.properties`, which never wrote `server-port` before. This lookup is Modrinth HTTP and stays in Node (a small CLI called from Bash, printing the chosen version and the list of notices). The chosen version is written to `variables.json`.
5. **Power-user with no config and no TTY:** unchanged: create `variables.json` from the example and exit non-zero with the instructions. The new `--default` flag runs the Default route non-interactively and **requires `--agree-eula`** to be given explicitly.
6. **Xaero patches are part of the shared install pipeline, not the wizard.** They run for every route whenever a Xaero mod is installed by the suite, because the config problem is a property of the mods, not of the route. Setup does not start the server just to generate files. It creates each file containing only the key line when the file is absent, and patches the key in place when it exists; an untested assumption is whether the mods fill in the other keys when the file is partial, so the first Xaero task verifies it with a throwaway server or documents the fallback ("start once, then patch and restart"). A `manage.sh doctor` check reports drift (a key missing or wrong) with the fix command, which covers later mod updates. The same script is called after suite-driven Xaero mod updates (last wave, small).
7. **Available RAM** means the lower of `MemAvailable` and the cgroup limit (`memory.max`) when one is set, read at decision time.
8. **Machine far below a working size:** proceed with the smallest working value and a red warning that says the server may be slow or fail; do not block.
9. **The Default route does not ask for an instance name or Minecraft version** (decision 3 and 4 cover the edge cases).

**Other calls:** keep `main.sh` as the entry; `--default`/`--guided` flags and route selection; `src/wizard/` layout; fallback to Default when whiptail is unusable; EULA as an explicit visible step; the memory rule; RCON port handled like the server port; the optional BC-006 helper; the test approach.
