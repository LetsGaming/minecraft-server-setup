# Research: setup and onboarding UX of comparable tools

Research date: 2026-10-20. Research only: no plan, no recommendations, nothing installed or executed.

Labels used throughout: **V** = verified in the tool's source or official docs, **I** = inferred by the researcher, **R** = reported by users (issue tracker, forum), not verified.

---

## 1. Executive Summary

**Most instructive findings**

1. **The expert/novice split is solved by hiding, not removing.** Debian's installer tags every question with a priority and shows only high and critical by default; the same question set serves experts at `priority=low` and unattended runs via preseed (V). PiVPN reaches the same effect with one `--defaultno` yes/no that lists the defaults inline and asks "customize?" (V). community-scripts has three tiers: zero-question Default, a 31-step Advanced wizard, and saved defaults (V).
2. **Dual-mode is built into each question, not bolted on.** raspi-config runs one `do_*` function for interactive and `nonint` use (V). PiVPN has a `runUnattended` branch inside every ask function that validates supplied values (V). Certbot gives every prompt a `default` and a `cli_flag`, and its non-TTY error names the flag to add (V). gh and rclone do the same with flags and declarative option metadata (V).
3. **No examined tool derives the Java heap from host RAM.** Fixed defaults: LinuxGSM 1024 MB, MSM 1024 MB, PufferPanel 2048 MB, itzg 1G (V). Only itzg offers a percentage form (`MEMORY=<n>%`), and only LinuxGSM reads host RAM, to print a non-blocking warning below a per-game floor (V). Paper's own docs disagree: one page says at least 6-10 GB, another says try no flags first on Java 17+ (V).
4. **The CurseForge key step is removed from end users by embedding a project-owned key** in itzg, packwiz and Prism, each with an override (V). Modpacks are selected by slug or URL in itzg and packwiz; PufferPanel's template still asks for numeric `projectId` and `fileId` (V). The residual manual step is mods that CurseForge does not allow to be distributed (Prism watches the downloads folder) (V).
5. **Networking guidance is the weakest area across the whole field.** Only Crafty (web UI) shows a port-forwarding reminder, at the moment of first server start (V, docs). LinuxGSM has no such text in any of 165 modules (V). PiVPN configures the host firewall automatically but has no router-forwarding text, and forum threads about it recur (R). Certbot's failure hint is the nearest thing to in-flow guidance and does not explain port forwarding (V).
6. **"Generate a file, then exit with an error" is a known pattern, and what differs is the message.** itzg exits 1 on missing EULA but prints the Mojang URL and the exact fix (V). LinuxGSM prompts Y/n and writes `eula=true` itself (V). Crafty asks in a dialog at first start of a server (V, docs). Certbot's ToS prompt is explicit with a named `--agree-tos` flag (V).
7. **Terminal-only is sufficient for the question flow but hits real walls** at things outside the host: router port forwarding, obtaining a third-party API key, mods blocked from redistribution, and `curl | bash` TTY problems. Evidence in section 5.5.
8. **Dependency footprint:** whiptail is Priority important on Debian 12/13 and Ubuntu 24.04 (about 25 KB download plus libnewt, libslang2, libpopt0) but is missing from the Ubuntu minimal cloud image; dialog is absent from every inspected Ubuntu image (V). Among Node prompt libraries only built-in `readline/promises` has zero dependencies; `@clack/prompts` needs Node >=20.12 and `inquirer` >=20.17, while Ubuntu 24.04 ships Node 18.19.1 (V).

**Main limitations of this research**

- Nothing was run. All prompt wording and behavior is read from source or docs; runtime behavior, including non-TTY behavior of whiptail and Node libraries, is not observed.
- Several candidate tools were not examined (section 3.3). ServerPackCreator was only skimmed (README).
- Complaint evidence is mostly single threads and search snippets, labeled R and not generalized.
- Subagents gathered the per-tool evidence; the report author read their notes, not every primary source. Claims were not independently re-fetched, except the baseline, which was read directly from the project.

---

## 2. Baseline: this project's current setup path (yardstick)

Read read-only from `readme.md`, `main.sh`, `src/common/*.sh`, `variables.example.json`, `src/setup/common/loadVariables.js`, `download_packages.sh`. Setup was not run.

**Stack and platform (V).** Bash 4.3+ and Node 18+; Debian/Ubuntu only (`download_packages.sh` uses `apt`); systemd and cron required. Node is a prerequisite the project does not install (`npm install` is step 2). `check_root` refuses root and `require_sudo` needs `sudo -v`; runs as `sudo -u <user> bash main.sh`. Runtime dependencies are `axios` and `semver` only.

**Path (V).**
1. `git clone`, `npm install`.
2. First `main.sh` run: `ensure_variables_json` copies `variables.example.json` to `variables.json` (umask 077), prints "Edit it ..., then run this again", exits 1.
3. User edits a roughly 90-line strict JSON file. The README shows it as `jsonc` with comments, and its snippet has a missing comma after `API_KEY`.
4. Modpack only: copy and edit `curseforge_variables.json` (`pack_id`, `api_key`, both `"none"` in the example).
5. `main.sh --check` (preflight), then `main.sh` or `main.sh --vanilla`.
6. Five yes/no prompts via `ask_yes_no` (start server, EULA, systemd service, backup job, API wrapper), each looping on invalid input; `--y` accepts defaults and sets EULA true. The README documents this.

**Config mechanism (V).** One JSON file, validated by `loadVariables.js` before downloads begin: memory strings must match a pattern, GC must be one of the allowed values, the placeholder API key and keys shorter than 32 characters are rejected. `variables.example.json` ships `minMemory`/`maxMemory` of `12G`, `alwaysPreTouch: true`, and an API port of 3030 (README text says default 3000).

**RAM handling (V, with a caveat).** `loadVariables.js` reads `MemAvailable` from `/proc/meminfo` and writes a non-blocking `[WARN]` to stderr if `maxMemory` exceeds it. It does not choose a default from RAM. `resolve_instance_vars` in `src/common/setup.sh` invokes the loader with `2>/dev/null`, so on that call path the warning is not shown; whether `--check` surfaces it was not verified.

**Safety and recovery (V).** `--check` preflight (tools, config, disk space, optional settings); `--dry-run`; `snapshot_setup_state` before the first change and `run_rollback` on failure or Ctrl-C, removing only what the run created; `manage.sh doctor` for installed instances; `migrate.sh` and documented upgrade path.

**Docs structure (V).** Single `readme.md` (features, prerequisites, config, usage, runtime scripts, webhooks, API wrapper) plus `docs/` topic files (backup-restore, sudoers, service-user, reverse-proxy, secrets, upgrade, migrations, glossary). No quick-start section, no "what is this" for non-IT readers, no networking, port-forwarding, firewall or "how to join" text in the files read.

**Known weak points for non-IT users (as given in the task, confirmed in the files above):** hand-edited strict JSON, Java heap/GC settings in the first-run file, RCON vs screen choice, CurseForge credentials, no networking guidance, config-generating first run that exits 1.

---

## 3. Scope and Method

### 3.1 Tools examined

**Group 1, similar tools (game servers, modpack side)**

| # | Tool | Why included | Delivery (constraint note) |
|---|---|---|---|
| 1 | LinuxGSM | Bash game-server manager; closest in stack and audience | Bash, curl, tmux; adoptable |
| 2 | itzg/docker-minecraft-server | Most-used Minecraft server setup; widely praised docs | Docker: UX only |
| 3 | Crafty Controller 4 | Non-IT-targeted Minecraft panel with terminal installer | Web UI: UX only |
| 4 | MSM (msmhq/msm) | Most-starred Bash-only Minecraft manager; deliberate contrast (maintenance mode, args-only) | Bash |
| 5 | PaperMC getting-started docs and downloads service | Where most users learn memory/Java guidance | Docs |
| 6 | Fabric installer | CLI-with-latest-defaults precedent | GUI mode off-limits; CLI mode adoptable |
| 7 | Prism Launcher and packwiz | Modpack/CurseForge key handling for non-technical users | Prism is a desktop GUI: UX only; packwiz is a Go CLI |
| 8 | PufferPanel templates | Declarative question schema | Web UI: UX only |
| 9 | ServerPackCreator | Pack-to-server conversion (README skim only) | CLI/GUI/Web; shallow |

**Group 2, non-IT tools elsewhere**

| # | Tool | Why included |
|---|---|---|
| 10 | Pi-hole `basic-install.sh` | Widely used home-user installer; dialog TUI; criticized for unattended gaps |
| 11 | PiVPN | Port, public IP and firewall questions; default-vs-custom gate |
| 12 | raspi-config | Beginner menu with `nonint` mode |
| 13 | Debian installer / debconf | Reference for priorities, ordering and preseed |
| 14 | Certbot | Defaults plus flags per prompt; consent and error-message design |
| 15 | community-scripts (Proxmox VE Helper-Scripts) | Default/Advanced/saved-defaults tiers (Proxmox-specific parts are UX only) |
| 16 | Jellyfin `install-debuntu.sh` | Detect-confirm-proceed installer, tty trick |
| 17 | restic | Secret-loss warning, destructive-action refusal, dry run |
| 18 | rclone config | Terminal-only wizard over a very large option space |
| 19 | `gh auth login` | Prompt-only-when-needed with a flag per prompt |

**Cross-cutting dependency research** (section 5.5): whiptail and dialog; Bash prompt patterns in rustup, Homebrew, Oh My Zsh, nvm; Node prompt libraries; system detection tools; WSL2/systemd.

### 3.2 Sources and rigor

Primary sources: GitHub/GitLab raw source, official docs, man pages, Debian/Ubuntu package indexes and image manifests, npm registry metadata. Secondary (labeled R): forum threads, issue trackers, search snippets. Where docs and code disagreed it is noted (LinuxGSM's Minecraft page says Java 16 while its code requires newer; Paper's two pages disagree on tuning).

### 3.3 Not examined or excluded

| Tool | Reason |
|---|---|
| Pterodactyl, AMP | Same web-panel category as Crafty/PufferPanel; time-boxed |
| Tailscale CLI | Not reached; Certbot used for the same question |
| CasaOS, Umbrel | Web-first, Docker-based; Jellyfin used for the terminal-installer angle |
| ATM-style `startserver.sh` pack installers | Not reached |
| Kopia, BorgBackup, Duplicati | restic chosen as the single backup exemplar |
| Plex installer | Closed source, cannot read mechanism |
| Docker Desktop, Electron launchers | Off-limits delivery and not instructive for terminal flow |

Gaps inside examined tools: LinuxGSM "getting started" docs page (URL guess 404); raspi-config README (404); `docs.pivpn.io/unattended` (404, source used instead); Crafty first-run credentials file (search snippets only); Jellyfin script not read to its end; ServerPackCreator CF-key behavior unchecked.

---

## 4. Tool Findings

Comparison table first, then compact entries. "Heap" = how the Java heap default is set. "Net" = in-flow networking/port-forwarding/join guidance. "Dual" = how interactive and non-interactive modes relate.

### 4.1 Comparison table

| Tool | Config style | Questions asked | Heap default | Env detection | Net guidance | Dual-mode mechanism | Preflight / dry-run / rollback |
|---|---|---|---|---|---|---|---|
| LinuxGSM | Layered bash `.cfg` files | Server pick, EULA Y/n, sudo | 1024 MB fixed | RAM floor warning, Java version vs MC, sudo detection | None (0 hits in 165 modules) | `auto-install` | Exit-code taxonomy; no dry-run/rollback found |
| itzg | Env vars | None required beyond EULA flag | 1G fixed or `%` | None beyond % option | "Point client at host/IP:25565" | Env-only | Idempotent restart; DEBUG flags |
| Crafty (UX only) | Web forms | Wizard in browser; installer y/n x3 | Form field | Distro detection; sudo state | Port-forward reminder at first start | `unattended` in config | `cleanup_bad_install` |
| MSM | `msm.conf` shell vars | None | 1024 MB fixed | `which java` | None found | Args only | Named error codes |
| Paper docs | Docs only | n/a | Docs: 4G example; Aikar page 6-10 GB | n/a | n/a | n/a | n/a |
| Fabric installer | CLI flags | None in CLI | n/a | Needs Java | n/a | Flags (defaults "latest") | n/a |
| packwiz / Prism | CLI / GUI | Slug, URL or search | n/a | n/a | n/a | Flags | Prism watches downloads folder for blocked mods |
| PufferPanel (UX only) | Template JSON to web form | Per-field schema | 2048 MB fixed, locked | `javadl` step | n/a | Panel/API | Conditional steps |
| Pi-hole | `dialog` TUI to toml | About 6 on fresh install | n/a | Interface, IPv4 route, systemd-resolved | Static IP warning only | `--unattended` (undocumented, upgrade-oriented) | Fresh/existing gate; temp log |
| PiVPN | `whiptail` TUI | Defaults gate, port, endpoint, DNS | n/a | Disk, OS, subnets, public IP, ufw/iptables | Host firewall automatic; no router text | `--unattended <file>`, branch per ask function | Existing-install menu |
| raspi-config | `whiptail` menus | Per setting | n/a | Pi model, partitions | n/a | `nonint <fn> <arg>` same function | Reboot prompt |
| Debian installer | Text/newt frontends | Priority-filtered | n/a | Network DHCP then manual | n/a | Preseed + priority | Auto-escalates priority on problems |
| Certbot | Prompts + flags | Email, ToS, domains | n/a | Port bind errors | Failure hint only | Default + `cli_flag` per prompt | `--dry-run` (staging) |
| community-scripts | `whiptail` | 0 (Default) or 31 steps | 1024 MB RAM default LXC | Template availability, storage | n/a | Env vars, `.vars` files | Summary echo before create |
| Jellyfin script | Bash | 0 (asks only if OS unknown) | n/a | OS, arch, disk, fs type | n/a | `SKIP_CONFIRM` | Refuses bad fs with reason |
| restic | CLI | Password x2 | n/a | n/a | n/a | Env/password-file | `--dry-run`, no-policy refusal |
| rclone | Prompt engine | Per option | n/a | n/a | n/a | `config create` from same metadata | Keep/Edit/Delete confirm |
| gh | Prompts + flags | Only when needed | n/a | n/a | n/a | Flag per prompt | Echoes equivalent command |

### 4.2 Group 1: similar tools

**LinuxGSM** (GameServerManagers/LinuxGSM). Bash game-server manager, pushed 2026-10-18, about 4.9k stars (V, GitHub API).
- Setup: `linuxgsm.sh` (curl required, else `[ FAIL ]`), pick server from a menu (whiptail/dialog if present, else Bash `select`) or name it as the argument, then `./mcserver install`. About 4 commands; decisions: server, EULA, sudo (V, `linuxgsm.sh`, `command_install.sh`).
- Config: three bash layers, `_default.cfg` (overwritten on update), `common.cfg`, instance cfg. Minecraft defaults `javaram="1024"`, `mcversion="latest"` (V). No wizard, no validation beyond Bash.
- EULA: `fn_prompt_yn "Continue?" Y`, default yes, prints the Mojang URL, writes `eula=true` (V, `install_eula.sh`).
- Env awareness: `check_deps.sh` detects distro, tries `sudo -n true`, else prints the exact apt command when sudo is unavailable (V). Java major is set from `mcversion` (V; thresholds not fully read). `check_system_requirements.sh` compares `physmemtotalgb` to a per-game floor (mc: 1 GB) and prints a warning, sleeps 5 s, does not block (V). Does not derive heap (V). Refuses non-x86 (V).
- Errors/recovery: coloured status lines, per-command logs, exit codes mapped to "Install Failed / Completed with Errors / with Warnings" (V). Day-2: `details`, `monitor` (cron), `backup`, `console`, `debug`, `postdetails` (V). No dry-run or rollback found (I, not searched exhaustively).
- Net: none (regex for port-forward/firewall/ufw/iptables/UPnP across 165 modules: 0 hits) (V). Docs drift: Minecraft page states Java 16 (V).
- Constraint check: adoptable (Bash only). R: tracker shows dependency/sudo issues, nothing Minecraft-onboarding-specific that recurs.

**itzg/docker-minecraft-server.** About 14.5k stars, release 2026.10.0 (V, API). Docker is off-limits; UX only.
- Setup: one `docker run ... -e EULA=TRUE` or a 3-step compose; "Point your client at host name/IP port 25565" (V, docs/index.md).
- Config: env vars only; `VERSION` accepts LATEST (default), SNAPSHOT or specific, re-resolved on each restart; `TYPE` selects the server flavor (V).
- Memory: `MEMORY=1G` default, separate `INIT_MEMORY`/`MAX_MEMORY`, `<n>%` form mapped to `-XX:InitialRAMPercentage/MaxRAMPercentage`, `USE_AIKAR_FLAGS` opt-in, `DEBUG_MEMORY` (V).
- EULA: if `eula.txt` absent and `EULA` not true, logs 4 lines (URL and "add `-e EULA=TRUE`") and `exit 1` (V, `scripts/start`). Same shape as this project's first run; the message contains the exact fix.
- CurseForge: `TYPE=AUTO_CURSEFORGE` with `CF_SLUG` or `CF_PAGE_URL`; a project-owned key is included on Java 17+ images, override via `CF_API_KEY`/`CF_API_KEY_FILE`; docs warn `$` must be doubled in compose (V).
- Errors: named causes, `DEBUG`/`DEBUG_EXEC` documented (V). Docs split by topic (types, versions, mods, config, troubleshooting) (V).
- R: CurseForge/modpack setup dominates support (issues #2626 key rejected and `$` escaping, #3750 mutually exclusive slug and URL, #1440 docs navigability led to the docs site).
- Constraint check: Docker not adoptable. Transferable: single consent flag with fix-it message, version keywords, percentage memory, opt-in Aikar flags, embedded CF key, slug-based pack pick, topic-split docs, DEBUG switches. The env-var surface would become flags/prompts.

**Crafty Controller 4** (web panel, GitLab; last activity 2026-10-19, V). UX only.
- Terminal installer: `install_crafty.sh` runs `sudo -v`, distinguishes sudo missing (127) from restricted (1) with distinct messages pointing to docs, detects the package family, then `install_crafty.py` asks three validated y/n/path questions, each showing the default (requirements, install directory, service file), with `get_user_valid_input` re-ask loop; `unattended` in config skips the branch question; `cleanup_bad_install` helper exists (V). Java is not installed by it; docs still list openjdk-8 (V).
- First run: browser to `https://<host>:8443` with a self-signed certificate. Initial credentials in a generated file (R, search snippets, not read in primary docs); a forum thread about creds not working exists (R).
- Server creation: browser form with type, version, min/max RAM, port; EULA confirmed in a dialog at first start of that server; then "a quick reminder to make sure your ports are forwarded if you want to access it remotely" (V, docs). RAM detection not verified (I).
- R: tracker has a run of closed security issues (stored XSS, path traversal): the attack surface of a web panel.
- Constraint check: web UI not adoptable. Transferable: sudo preflight with distinct messages, defaults shown on each question, `unattended`, EULA confirmed when the server first starts, port-forward reminder at the moment of first start, zip import. Credentials-in-a-file first run looks fragile (R).

**MSM** (msmhq/msm). About 1.26k stars; last real commit July 2024, a May 2026 merge only bumped a CI action: maintenance mode (V).
- Single Bash init script; install by `wget ... | bash`; Debian installer runs `apt-get update` and a full `upgrade`, installs headless JRE 17, which Paper docs say not to use (V).
- `msm.conf` annotated shell variables, `DEFAULT_RAM="1024"`, per-server override; `msm server create <name>`; no questions, tab completion (V). Named error codes (`JAVA_NOT_INSTALLED`); warns on start if `eula=true` is missing (V). No RAM or port guidance found (I).
- R: oldest open issues show silent failures (server.log empty after start).
- Constraint check: Bash; concepts only (named error codes, per-server overrides). Not a novice model.

**PaperMC docs and downloads service.** Source: PaperMC/docs.
- Getting-started: requirements table (Java by MC version), download, run `java -Xms4G -Xmx4G -jar paper.jar --nogui` ("change the numbers"), or use a start-script generator (V).
- Aikar page: use at least 6-10 GB; leave 1000-1500 MB for the OS on shared hosts; Xms equals Xmx. The start-script-generator page says try no flags first on Java 17/21+. Paper's pages disagree (V).
- EULA: `-Dcom.mojang.eula.agree=true` documented in reference (V). Java page: Corretto via apt, "do not use headless variants" (V). Downloads API requires a non-generic User-Agent with a contact URL or email (V).

**Fabric installer.** Swing GUI when run without arguments; CLI `server` mode with `-dir`, `-mcversion` (default latest), `-loader` (default latest), `-downloadMinecraft` (V, `ServerHandler.java`). Needs Java already; no EULA/RAM handling seen (V). GUI mode off-limits; CLI-with-"latest" defaults adoptable.

**Prism Launcher and packwiz** (CurseForge key handling).
- Prism (Qt desktop GUI, off-limits as delivery): ships a project-owned key in `CMakeLists.txt` with a comment that derivative works must replace it; README ties use to CurseForge third-party API terms (V). `BlockedModsDialog` lists mods CurseForge does not allow to be distributed, with links, and watches the downloads folder until the files appear (V).
- packwiz (Go CLI): embeds a default key (override via ldflags), takes a project by URL, slug or search term, resolves dependencies (V).
- ServerPackCreator: README states the user is "still expected to be knowledgeable about your modpack ... server administration and Java" (V, README only; CF key behavior not checked).
- Pattern: all three working tools remove the key step from end users by embedding a project-owned key (V). Legal terms of shipping a key were not evaluated.

**PufferPanel templates** (web panel; templates are data). Template JSON `data` entries carry `display`, `type`, `value` (default), `required`, `userEdit`; install steps are conditional (`"if": "modlauncher == 'fabric'"`), including a `javadl` step that downloads the right Java automatically, and `run` uses `java${javaversion} -Xmx${memory}M` (V). Defaults: `eula` false and required, `version` "latest", `memory` 2048 MB with `userEdit=false`, `port` 25565. The CurseForge template needs integer `projectId` and `fileId` (V). Weakness: memory is a fixed integer; no host RAM detection (V). Web form not adoptable; the schema idea is.

### 4.3 Group 2: non-IT and other-domain tools

**Pi-hole `basic-install.sh`** (about 61k stars; pushed 2026-10-20; V).
- Flow: root check (re-exec via sudo), `check_fresh_install` (fresh iff neither `/etc/pihole/pihole.toml` nor `setupVars.conf` exists), package manager detect, FTL architecture check (aborts early on unsupported CPU), then only if fresh: welcome dialogs, "Static IP Needed" yes/no, interface, IPv4/IPv6, upstream DNS, blocklists, logging, privacy. About 6 decisions, each a `dialog` box. Config applied into `pihole.toml` via `setFTLConfigValue`.
- Question design: interface radiolist is auto-skipped when exactly one interface is up (`ip --oneline link show up`). Custom DNS input is validated (`valid_ip`), the invalid entries are listed, valid ones kept, and the user is re-asked; a summary yes/no confirms.
- Env awareness: `ip route get 8.8.8.8` for src IP; warning dialog if no IPv4 route; systemd-resolved stub listener disabled by writing a drop-in so port 53 is free; no RAM or disk check in the script (grep found none).
- Dual mode: `--unattended` and `--repair` are "undocumented flags" per the source comment; unattended takes effect only when not a fresh install. R: a fresh unattended run still shows the dialog (Pi-hole forum threads).
- Errors: per-step tick/cross lines, temp log, final summary tells the user which IPs to enter and the admin URL. Dependency: `dialog` is installed by the script.
- Static IP is only warned about (V).

**PiVPN** (about 8k stars, "best-effort maintenance" per README, V).
- Flow: root, flags, existing install, distro, hostname, disk space (75 MB via `df -Pk`), welcome and static-IP messages, user, interface, VPN type, **`askAboutCustomizing`**, protocol/port/DNS if customizing, public IP or DNS name, client DNS, unattended-upgrades question.
- `askAboutCustomizing` is a `--defaultno` yes/no: "PiVPN uses the following settings that we believe are good defaults for most users ... choose Yes to customize", listing the defaults inline (V, L2106).
- Port question: input box prefilled with the default, "hit Enter to retain the default", range check 1-65535, confirm yes/no (V). Public endpoint: public IP auto-detected via `dig +short myip.opendns.com @208.67.222.222`, then `curl https://checkip.amazonaws.com`; exits with a connectivity message if both fail; radiolist offers the detected IP or a validated DNS name (V).
- Existing-install menu: Update / Repair / Reconfigure with plain descriptions (V). Random VPN subnet chosen to avoid collisions with `ip route show` (V). OS support: untested OS gets a "may work" yes/no (V).
- Firewall: sets `ip_forward`, inserts ufw rules (backing up `before.rules` as `.pre-pivpn`, refusing empty files) or persistent iptables rules (V). **No router port-forwarding guidance in the installer** (grep, V). `pivpn -d` labels the protocol "you need to use in the port forwarding entry" (V, FAQ). R: forum threads on failed external connections after install.
- Unattended: `--unattended <file>`; each ask function has an `if runUnattended` branch that applies defaults, validates supplied values and exits with a message on bad input (V, about 20 functions).

**raspi-config** (V). POSIX `sh` plus whiptail; hierarchical menu with a short plain description under every item; Cancel relabelled "Finish"; `calc_wt_size` sizes boxes to the terminal. Global `INTERACTIVE=True`; `raspi-config nonint <function> <args>` runs the same function with `INTERACTIVE=False`, and each `do_*` function has an interactive and a non-interactive branch. Interactive prompts pre-select the current state (e.g. `--defaultno` computed from `get_ssh`). Warnings at the point of risk (SSH with weak passwords). Wifi country validated against ISO 3166 (V). Quirk: `do_ssh 0` means enable (shell exit-code convention); tutorials disagree (R). Root check message tells the fix: "Try 'sudo raspi-config'" (V).

**Debian installer / debconf** (V, Debian docs). Priorities: low = trivial questions with defaults that work in nearly all cases, medium = reasonable defaults, high = no reasonable default, critical = must be seen. Default install uses `priority=high` (medium/low skipped, defaults taken). `priority=low` is expert mode; `critical` means "do the right thing without fuss". The installer raises priority itself when a default fails. Question order: localization, then network (DHCP attempt with timeouts, fallback to manual), hostname, accounts, partitioning. Preseed via `preseed/url` or file with checksum; questions asked before the preseed loads cannot be preseeded. Frontends: noninteractive, text, newt (default), gtk.

**Certbot** (V, source and docs).
- Every prompt call passes `default` and `cli_flag`. Without a TTY the default is returned, or the error is "Unable to get an answer for the question ... You can provide an answer on the command line with the <flag> flag." A skipped-interaction warning names `--non-interactive`.
- ToS: explicit yes/no with `--agree-tos`; refusal raises "Registration cannot proceed without accepting". Destructive prompts use labelled buttons (`Deactivate`/`Abort`; `Yes (recommended)`/`No`).
- `--dry-run` uses the staging server. Failure messages carry remedies: bind failure says "you aren't running this program as root"; the validation failure hint says ensure the domains point to this machine and can accept inbound connections.
- R: "Timeout during connect (likely firewall problem)" is a frequent beginner failure caused by router or ISP port blocking.

**community-scripts / Proxmox VE Helper-Scripts** (about 30k stars; V, `misc/build.func`). Mode menu: Default (default item), Advanced, User Defaults, App Defaults. Preflight chain (`pve_check`, `root_check`, `ensure_whiptail`, `arch_check`, ...). Default mode asks nothing and prints a coloured summary of every value (ID, OS, disk, CPU, RAM) before creating; built-in defaults are raised to the app's declared minimums. Advanced is a 31-step wizard titled "[Step N/31]", where Cancel at step 1 exits and Cancel later means Back, with per-field validators. Saved defaults live in `default.vars` and per-app `.vars`, read with a whitelisted parser (no `source`/`eval`); precedence is env, then user defaults, then built-ins; after Advanced it offers to save answers as app defaults. Telemetry consent lists "What we collect / What we DON'T collect" and defaults to no. R: `curl | bash` trust concerns. `build.func` is about 285 KB (I: hard to audit).

**Jellyfin `install-debuntu.sh`** (V). Fails if not Debian-family, with an escape route; root check with the fix command; maps derivatives to upstream; asks `Repo OS:` / `Repo Release:` (with explanation) only when detection fails. Requires 2 GB in `/var/lib` and 1 GB in `/tmp`; refuses nfs/ceph with the reason, warns for zfs/btrfs. Prints the detected facts and "If this looks correct, press <Enter>", reading from `/dev/tty` so it works under `curl | bash`; `SKIP_CONFIRM` skips. Installs missing curl/gnupg with a sentence saying so.

**restic** (V). `init` asks the password twice and states "Losing your password means that your data is irrecoverably lost". Empty password is refused unless `--insecure-no-password`. `forget` without a policy fails with "no policy was specified, no snapshots will be removed"; `--dry-run` shows what would be removed; forget and prune are separate steps. Docs are example-first with literal terminal transcripts.

**rclone config** (V). One prompt engine (`CommandDefault`, `Confirm`, `Choose`, `Enter`) that prints its own rules ("Press Enter for the default (X)", "Choose a number from below, or type in your own value"). Menu adapts to state (no remotes: only new/set-password/quit). Provider options are declarative (Name, Help, Examples, Default, Required, Advanced), driving the wizard, docs and non-interactive `rclone config create name type key=value`. Invalid input produces specific messages and a re-prompt. A "Keep this remote?" summary precedes saving. R: the "Use auto config?" wording confused headless users and was reworded.

**`gh auth login`** (V). Prompts only when it can (`CanPrompt()`) and has no token; each prompt has a flag; conflicting flags are rejected explicitly; the result prints the equivalent non-interactive command.

---

## 5. Cross-Tool Synthesis

### 5.1 Patterns that consistently work

| Pattern | Demonstrated by | Mechanism |
|---|---|---|
| Hide questions with usable defaults; show the rest | Debian priorities, PiVPN defaults gate, community-scripts Default tier | Priority tag per question plus a filter level; or one yes/no listing defaults inline; or a zero-question mode that echoes a full summary before acting |
| Skip questions that have one answer | Pi-hole (one interface), PiVPN (detected public IP prefilled), Jellyfin (asks OS only if detection fails) | Detect first (`ip`, `dig`, `/etc/os-release`), ask only on failure or ambiguity |
| Show detected facts and confirm | Jellyfin, community-scripts Default, rclone ("Keep this remote?"), Pi-hole DNS summary | Print what was found/chosen, wait for Enter or yes/no |
| One code path for both modes | raspi-config, PiVPN, Certbot, rclone, gh | Branch inside the question function, or default plus flag per prompt, or option metadata feeding wizard and flags |
| Errors name the next step | Certbot (flag name, "run as root"), itzg (exact `-e EULA=TRUE`), raspi-config ("Try 'sudo raspi-config'"), Jellyfin (escape routes), LinuxGSM (exact apt command) | Message text carries the remedy at the failing check |
| Consent is explicit and nameable | Certbot `--agree-tos`, itzg `EULA=TRUE`, community-scripts telemetry opt-in | A named flag/variable; prompt shows the URL; refusal is a clean stop |
| Warn at the point of risk | raspi-config SSH, restic init, Crafty port-forward reminder | The warning appears in the step where the risk begins, not in a README |
| Destructive actions are hard to do by accident | restic (no-policy refusal, `--insecure-no-password`), Certbot (Deactivate/Abort labels), PiVPN (backs up `.rules`) | Refuse on missing policy, scary flag names, labelled buttons, backups of edited system files |
| Existing-install awareness | Pi-hole fresh/existing gate, PiVPN Update/Repair/Reconfigure, raspi-config reading current state | Detect prior state and switch between ask-everything, ask-nothing and a menu |
| Remove third-party credential steps | itzg, packwiz, Prism (embedded CF key with override) | Project-owned key shipped in source; override variable |
| Remove Java as a user concern | PufferPanel `javadl`, LinuxGSM version-aware check, this field's Java-per-MC-version tables (Paper) | Conditional install step or lookup table keyed by MC version |
| Show the user what they can type next | gh (equivalent command echoed), rclone (rules printed per prompt), Certbot (renewal scheduled message) | Print the non-interactive equivalent or scheduled action |

### 5.2 Anti-patterns that consistently hurt

1. **Silent consent paths.** Crafty and LinuxGSM confirm the EULA at an identifiable moment; itzg, Certbot and community-scripts name the consent. This project's `--y` accepts the EULA as a side effect of "take the defaults" (documented, V). No examined tool was found to bundle EULA consent into a generic "yes to everything" flag, but this was not searched exhaustively (I).
2. **Unattended mode that does not cover a fresh install.** Pi-hole's `--unattended` takes effect only on existing installs; fresh unattended still shows the dialog (V in source, R in forum).
3. **Jargon in option names.** rclone's "Use auto config?" produced recurring headless-machine confusion and was reworded (R). raspi-config's 0 = enable is a recurring trap (R).
4. **Docs and code drift.** LinuxGSM docs say Java 16; Crafty's manual steps list openjdk-8; Paper's tuning pages contradict (V). The README of this project shows a snippet with a missing comma and an unreconciled port default (V, baseline).
5. **Fixed small heap defaults with no host awareness.** LinuxGSM, MSM, itzg, PufferPanel use 1-2 GB; Paper docs recommend 6-10 GB. No examined tool reads host RAM to choose a default (V). The fixed value is wrong for some hosts in either direction.
6. **Networking left to the user's search.** PiVPN and Certbot generate recurring "can't connect from outside" threads (R); LinuxGSM has no text at all (V).
7. **Third-party credentials as a manual step.** itzg's recurring CurseForge issues (key rejected, `$` escaping, slug vs URL) show friction even after the key was bundled (R); PufferPanel still asks for numeric ids (V).
8. **Credentials-in-a-generated-file first run** (Crafty; R).
9. **Hard-to-audit giant installers** (community-scripts `build.func` about 285 KB) and `curl | bash` trust concerns (R).
10. **Full system upgrade as a side effect.** MSM's Debian installer runs `apt-get upgrade` (V). This project already makes that opt-in (`MC_SETUP_UPGRADE_SYSTEM`, V, `download_packages.sh`).

### 5.3 How tools handle the expert/novice split

| Strategy | Example | Trade-off (I unless noted) |
|---|---|---|
| Question priority filter | Debian debconf (V) | Same question set; needs per-question annotation and discipline; novices never see low-priority questions |
| Defaults gate with inline defaults | PiVPN (V) | One extra question; novice sees what they accept; expert answers once to unlock all |
| Mode tiers | community-scripts Default / Advanced / saved defaults (V) | Three code paths to keep consistent; saved defaults turn Advanced sessions into future Default runs |
| Interactive by default, a flag per prompt | gh, Certbot, rclone, raspi-config nonint (V) | Flag sprawl; the prompt/flag mapping is the contract; Certbot shows it can be enforced in the prompt layer |
| Config file is the expert interface, prompts for novices | LinuxGSM layered cfg (no prompts), PiVPN `--unattended <file>` (V) | Files stay hand-edited unless generated; LinuxGSM has no validation (V) |
| Env vars only | itzg, nvm, Homebrew (V) | Excellent for automation; poor discoverability without docs; itzg mitigates with a docs site |
| Separate quick-start vs reference docs | itzg docs, restic docs (V) | Two documents to keep aligned; docs drift is observed in LinuxGSM and Crafty |
| Auto-escalating priority | Debian installer raises priority on problems (V) | Failure turns a hidden question into a visible one |

Evidence on degrading the other side: no examined tool lost expert capability by adding a novice flow. Pi-hole's dialogs are skipped when config exists, so experts are not blocked by them (V); the expert gap there is the reverse, an unattended path that does not cover a fresh install (V/R).

### 5.4 What terminal-only tools achieve, and where they hit a wall

**Achieved without a GUI (V):** full multi-step wizards (Pi-hole, PiVPN, rclone about 70 backends, community-scripts 31 steps with Back), state-aware menus (rclone, raspi-config), validated free-form input with re-ask (Pi-hole DNS, PiVPN port, Crafty `get_user_valid_input`), confirmation summaries, step counters, and consent flows.

**Walls (V or R as marked):**
- **Router port forwarding.** It happens on another device. No examined terminal tool explains or automates it in-flow: PiVPN has host-firewall automation but no router text (V); Certbot reports a failure (V) and the common beginner outcome is a forum thread (R). The only in-flow reminder found is Crafty's, in a web UI (V, docs). Whether any examined tool automates UPnP was not checked beyond LinuxGSM's zero hits.
- **Third-party credentials and consent pages.** Getting a CurseForge key is a browser task. Tools that avoided it did so by embedding a key (V), not by a terminal flow.
- **Files that must be downloaded manually** (CurseForge-blocked mods). Prism solves it with a GUI dialog plus folder watcher (V); no examined terminal tool handles it.
- **TTY availability.** `whiptail` has no plain-text fallback and exits 255 on terminal-init failure; it fails under a piped stdin (V in source, R in reports); Homebrew, rustup and Pi-hole each carry explicit `-t 0` / `/dev/tty` handling (V).
- **Locale and terminal quirks.** Box-drawing garbage with some `TERM`/locale combinations (R). `whiptail` has no input validation and needs manual sizing (V).
- **Unattended coverage of dialogs.** Pi-hole fresh unattended (V/R).
- **Windows.** whiptail and dialog do not exist natively; WSL2 supports systemd since WSL 0.67.6 (Sept 2022) with `[boot] systemd=true` in `/etc/wsl.conf` (V). Pure-JS prompt libraries run in Windows terminals (V).

### 5.5 How tools keep the dependency footprint small

**TUI layer (V, package indexes and manifests, 2026-10-20):**

| Option | Presence on stock images | Size | Notes |
|---|---|---|---|
| `whiptail` (package `whiptail`, libs newt/slang2/popt) | Priority important on Debian 12/13 and Ubuntu 24.04. In Ubuntu server ISO and server cloud image; **not** in Ubuntu minimal cloud image. Debian cloud images not checked. | About 25 KB download, 61 KB installed; libslang2 about 2.4 MB | Widgets: msgbox, yesno, inputbox, passwordbox, menu, checklist, radiolist, gauge. Results on stderr, exit 0/1/255. No validation. Manual sizing. No non-TTY fallback. Used by raspi-config, PiVPN, community-scripts |
| `dialog` | Priority optional; universe on Ubuntu; absent from every inspected Ubuntu image | About 126 KB download, 493 KB installed plus libs | Richer widgets, DIALOG_* env vars, `--output-fd`. Pi-hole installs it as a dependency |
| Plain Bash `read` | Always present | 0 | `read -r -p`, `read -s`, `select`, validation loops. Used by Oh My Zsh (`[Y/n]` with `case`), Homebrew (`wait_for_user` raw-key read), nvm (no prompts at all) |
| Node built-in `readline/promises` | Node 17+; Stable in v18 docs | 0 | Zero dependencies; no widgets |
| `@clack/prompts` 1.8.1 | npm | About 183 KB with 5 transitive deps | ESM-only, Node >=20.12; used by create-vite, create-vue, create-nuxt, sv, create-t3-app |
| `prompts` 2.4.2 | npm | About 214 KB, 2 transitive | CJS; used by create-next-app |
| `enquirer` 2.4.1 | npm | About 225 KB, 3 transitive | CJS |
| `inquirer` 14.2.4 | npm | About 1.0 MB, 26 transitive | ESM-only, Node >=20.17 |
| `gum` (Go binary) | Debian 13 only (3.3 MB), not Ubuntu 24.04 | Separate binary | Separate install channel |

**Node versions (V, endoflife.date and package indexes):** Node 18 EOL 2025-04-30, Node 20 EOL 2026-04-30; Ubuntu 24.04 ships Node 18.19.1 (universe), Debian 13 ships 20.19.2, Debian 12 ships 18.20.4. A stated minimum of Node 18 matches the distro versions but not the declared engines of current `@clack/prompts` and `inquirer` (older majors not evaluated).

**How the better tools keep it small (V where stated):**
- Pure Bash with environment switches for non-interactive use: Homebrew (`NONINTERACTIVE`, `CI`, `INTERACTIVE`, stdin-not-a-TTY detection), Oh My Zsh (`--unattended`, `RUNZSH`/`CHSH`, `[ ! -t 0 ]`), nvm (no prompts, env vars only).
- A shim that hands off to a compiled program and reattaches `/dev/tty`: rustup-init re-execs with `< /dev/tty` when stdout is a TTY, otherwise errors "Run with -y to accept defaults" (V). The interaction lives in the binary.
- Single static binary with a built-in prompt engine: rclone, restic, gh (V).
- A TUI package already on most images: raspi-config, PiVPN with whiptail (V). Pi-hole chooses dialog and installs it (V).
- No verified example of a Debian/Ubuntu Bash installer that embeds a Node wizard (searched, none found; n8n not inspected).

**Costs (I):** whiptail ties the wizard to Linux and breaks on minimal images and non-TTY stdin; Bash prompts cost hand-written validation and are the same everywhere; Node libraries bring Node-version coupling and an `npm install` before the wizard can run (this project already requires `npm install` before first use, V).

**Detection without extra packages (V, man pages):** `/proc/meminfo` (`MemTotal`, `MemAvailable`); `memory.max` exists on non-root cgroups and may report `max` (V) while `/proc/meminfo` inside LXC may be virtualized only with LXCFS (R); `nproc` reports processing units available to the process (V; whether it honors cgroup CPU quota not verified); `ss -ltn 'sport = :PORT'` and `ip route get` need `iproute2` (Priority important on Debian 13 and Ubuntu 24.04, in all inspected Ubuntu manifests including minimal, V); `systemd-detect-virt` reports `lxc`, `wsl`, `docker` etc.; `ufw` is Priority standard and in Ubuntu server images but disabled by default, and is Priority optional on Debian (V); `curl` is Priority optional but present in every inspected Ubuntu image; `cron` is absent from the Ubuntu minimal cloud image (V).

### 5.6 Where this project stands (comparative positioning only)

**Matches or exceeds the field**
- Rollback of a failed setup (snapshot before first change, remove only what the run created). Among examined tools only Crafty's `cleanup_bad_install` is comparable (V); no rollback was found in LinuxGSM or MSM (I).
- Preflight `--check` plus `--dry-run`. Certbot has `--dry-run`; LinuxGSM and MSM have no preflight command found (I). Config validation before any download matches PiVPN/Debian-style early checks.
- `doctor` day-2 health check; LinuxGSM's `details`/`monitor` is the nearest equivalent.
- Secrets handling: `variables.json` created with umask 077 and git-ignored; placeholder API key rejected (V). Comparable care was not seen in the game-server tools examined.
- Opt-in system upgrade where MSM upgrades unconditionally.
- sudo and root preflight with a message that states the fix (matches raspi-config, Crafty).

**Parity with the field (no examined Minecraft tool does it either)**
- No default heap derived from RAM. A non-blocking warning against `MemAvailable` exists in `loadVariables.js`, similar in effect to LinuxGSM's floor warning, though pointed at the opposite direction (configured value too large vs host too small), and its visibility on the setup path is uncertain (see baseline).
- No router port-forward guidance (LinuxGSM, MSM, PiVPN, Certbot also lack it in-flow).

**Behind comparable tools**
- Configuration is hand-edited strict JSON. LinuxGSM's layered cfg is also hand-edited but forgiving Bash; itzg is env-var based with sane defaults; PiVPN, Pi-hole, raspi-config, rclone, Crafty and PufferPanel ask for the decisions.
- No question-level hiding or default-vs-advanced gate (Debian priorities, PiVPN, community-scripts).
- Prompts cover consent and feature toggles but not the decisions with most impact (version, RAM, name, vanilla vs modpack are in the JSON file, V). LinuxGSM also does not ask version or RAM (V), so this is parity with it and behind the wizard-style tools.
- CurseForge credentials are a user step; itzg, packwiz and Prism embed a key. Pack selection is a numeric `pack_id` as in PufferPanel's template; itzg and packwiz accept slugs/URLs.
- First-run exit 1: the message does say what to do, as itzg's does; the exit status is the same shape (V).
- `--y` accepts the EULA; Certbot requires `--agree-tos` by name, itzg `EULA=TRUE`, LinuxGSM prompts with a default yes (V).
- No quick-start, no "what is this", no how-to-join text (itzg's index has the join sentence, Crafty has the reminder, V).
- README/example inconsistencies (port default, missing comma, `jsonc` presented as the config) as an instance of the docs-drift anti-pattern.
- Linux/Debian/Ubuntu-only with apt; Node 18+ is a stated prerequisite that is not installed by the tool (the field varies: LinuxGSM installs deps through sudo, Crafty installs Python deps, Pi-hole installs `dialog`).

---

## 6. Off-Limits Observations

Recorded so these ideas are not silently re-proposed. For each: what it is, why it is off-limits, and what survives.

| Idea (tool) | Why off-limits | What survives without the mechanism |
|---|---|---|
| Browser-based server creation form and ongoing management (Crafty, PufferPanel, Pterodactyl-class panels) | Web UI | The question set, default values, required/locked field schema (PufferPanel `userEdit=false`), the EULA-at-first-start moment, the port-forward reminder at first start. Panels also carry reported security-issue history (Crafty, R), unrelated to the UX but relevant to adoption |
| Docker image tags choose Java; Compose as the quick start (itzg) | Docker | `VERSION` keywords, percentage memory, opt-in Aikar flags, one-flag consent with exact fix message, topic-split docs |
| LXC creation with advanced settings (community-scripts) | Proxmox/containers | Default/Advanced/saved-defaults tiers, step counter, Back, summary echo, whitelisted `.vars` parser |
| Swing GUI mode of the Fabric installer | GUI | CLI `-mcversion`/`-loader` with "latest" defaults |
| Qt dialog listing blocked CurseForge mods and watching the downloads folder (Prism) | Desktop GUI | The concept (list blocked files with links, detect when the user has placed them) is terminal-expressible; no terminal tool was found doing it |
| Web-based start-script generator (Paper) | Web UI | Static tables of Java version per MC version; generator output as documentation |
| ServerPackCreator GUI/web modes | GUI | README states the audience expectations only |
| Telemetry-based diagnostics (community-scripts) | Not off-limits technically, but depends on a hosted service | The consent prompt design (what is collected, what is not, default no) |
| `dialog` as a mandatory dependency (Pi-hole) | Adds a package that is absent from stock Ubuntu images | `whiptail`-style flows; or plain prompts |
| CasaOS/Umbrel-style app stores | Docker plus web UI | None examined |

---

## 7. Open Questions

1. **Runtime behavior of whiptail and Node prompt libraries when stdin is not a TTY** (SSH without `-t`, piped, CI). Settled by running small test scripts on a Debian and an Ubuntu host.
2. **Debian cloud images and Raspberry Pi OS Lite defaults** for whiptail, curl, ufw, cron. Settled by reading image manifests or package lists.
3. **Whether `nproc` and `/proc/meminfo` report cgroup-limited values** on common VPS/LXC hosts. Settled by testing on LXC with and without LXCFS and on Docker-less VPS.
4. **Whether any terminal tool automates router port forwarding (UPnP/NAT-PMP) for game servers**, and with what reliability. Settled by searching Minecraft and general tooling for UPnP clients (only LinuxGSM was grepped).
5. **Legal and operational terms of shipping a project-owned CurseForge API key.** Prism's and packwiz's notes ask forks to obtain their own; CurseForge's current third-party API terms were not evaluated. Settled by reading those terms and the key-owner agreements.
6. **How often users hit the problems reported for each tool** (frequencies). Settled by counting labeled issues in the trackers; current evidence is single threads.
7. **Unexamined tools**: Pterodactyl, AMP, Tailscale CLI, CasaOS/Umbrel, ATM-style `startserver.sh` installers, ServerPackCreator internals. Settled by examining them.
8. **Whether this project's RAM warning is visible on the `--check` path** (it is discarded on the `resolve_instance_vars` path). Settled by reading `run_preflight_check` (section of `src/common/setup.sh` not read in full).
9. **Older major versions of `@clack/prompts` and `inquirer` and their Node 18 support.** Settled by reading their package metadata history.
10. **Whether any examined tool's first-run experience was measured with real non-IT users.** No usability studies were found; all UX judgments here are from mechanisms and reports.

---

## 8. Sources

**Group 1**
- LinuxGSM: https://github.com/GameServerManagers/LinuxGSM ; `linuxgsm.sh`, `lgsm/modules/command_install.sh`, `install_eula.sh`, `check_deps.sh`, `check_system_requirements.sh`, `core_getopt.sh`, `config-default/config-lgsm/mcserver/_default.cfg` (raw.githubusercontent.com/GameServerManagers/LinuxGSM/master/...) ; docs https://docs.linuxgsm.com/game-servers/minecraft ; API https://api.github.com/repos/GameServerManagers/LinuxGSM
- itzg: https://github.com/itzg/docker-minecraft-server ; docs/index.md, docs/versions/minecraft.md, docs/versions/java.md, docs/configuration/jvm-options.md, docs/types-and-platforms/mod-platforms/auto-curseforge.md, scripts/start ; issues #2626, #3750, #3112, #1440
- Crafty: https://gitlab.com/crafty-controller/crafty-4 ; installer https://gitlab.com/crafty-controller/crafty-installer-4.0 ; docs https://docs.craftycontrol.com/pages/getting-started/installation/linux/ , .../access/ , .../user-guide/server-creation/minecraft/ ; forum https://forums.truenas.com/t/crafty-4-creds-dont-work/56952 (R)
- MSM: https://github.com/msmhq/msm ; README.markdown, installers/install.sh, installers/debian.sh, init/msm, msm.conf
- PaperMC docs: https://github.com/PaperMC/docs ; paper/admin/getting-started/getting-started.mdx, paper/admin/how-to/aikars-flags.md, misc/tools/start-script-gen.mdx, misc/java-install.md, misc/downloads-service.mdx, paper/admin/reference/system-properties.md, paper/admin/misc/faq.md
- Fabric installer: https://github.com/FabricMC/fabric-installer ; `ServerHandler.java` ; https://fabricmc.net/use/server/
- Prism Launcher: https://github.com/PrismLauncher/PrismLauncher ; CMakeLists.txt, README.md, `launcher/ui/dialogs/BlockedModsDialog.cpp`
- packwiz: https://github.com/packwiz/packwiz ; `curseforge/request.go`, `install.go`
- ServerPackCreator: https://github.com/Griefed/ServerPackCreator (README only)
- PufferPanel templates: https://github.com/pufferpanel/templates (v3) ; `minecraft/minecraft.json`, `minecraft-curseforge.json` ; https://github.com/pufferpanel/pufferpanel

**Group 2**
- Pi-hole: https://github.com/pi-hole/pi-hole ; `automated install/basic-install.sh` ; https://docs.pi-hole.net/main/prerequisites/ , .../basic-install/ ; forum (R): https://discourse.pi-hole.net/t/pi-hole-6-3-unattended-zeigt-trotzdem-ncurses-dialog-bei-neuinstallation-ohne-pihole-toml/84187 , https://discourse.pi-hole.net/t/pi-hole-v6-1-install-issue-setupvars-conf-missing-ftl-on-port-80-scripts-non-interactive/80085
- PiVPN: https://github.com/pivpn/pivpn ; `auto_install/install.sh` ; https://docs.pivpn.io/faq/ , https://docs.pivpn.io/install/ ; forum (R): https://dietpi.com/forum/t/pivpn-not-connecting-externally/4936 , https://discourse.pi-hole.net/t/unable-to-connect-to-pihole-vpn-when-on-lte-and-public-wifi/7853
- raspi-config: https://github.com/RPi-Distro/raspi-config ; script `raspi-config` ; tutorial (R): https://raspberry.tips/en/?p=16284
- Debian installer: https://manpages.debian.org/stable/debconf-doc/debconf.7.en.html ; https://www.debian.org/releases/stable/amd64/ch05s03.en.html , apbs01, apbs02, apbs04 ; https://www.debian.org/releases/trixie/example-preseed.txt
- Certbot: https://eff-certbot.readthedocs.io/en/stable/using.html ; https://github.com/certbot/certbot (`_internal/display/obj.py`, `main.py`, `client.py`, `plugins/standalone.py`) ; forum (R): https://community.letsencrypt.org/t/error-timeout-during-connect-likely-firewall-problem/170852
- community-scripts: https://github.com/community-scripts/ProxmoxVE ; `misc/build.func`
- Jellyfin: https://repo.jellyfin.org/install-debuntu.sh ; https://github.com/jellyfin/jellyfin
- restic: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html , 060_forget.html , 040_backup.html ; https://github.com/restic/restic (`cmd/restic/global.go`, `cmd_forget.go`)
- rclone: https://rclone.org/commands/rclone_config/ , .../rclone_config_create/ ; `fs/config/ui.go` ; https://forum.rclone.org/t/idea-to-improve-wording-of-auto-config-during-configuration/33951 (R) ; https://rclone.org/remote_setup/
- gh: https://cli.github.com/manual/gh_auth_login ; https://github.com/cli/cli (`pkg/cmd/auth/login/login.go`, `pkg/cmd/auth/shared/login_flow.go`)

**Dependency and platform research**
- whiptail: https://manpages.debian.org/trixie/whiptail/whiptail.1.en.html ; https://github.com/mlichvar/newt (`whiptail.c`, `newt.c`)
- dialog: https://manpages.debian.org/trixie/dialog/dialog.1.en.html
- Package indexes: https://deb.debian.org/debian/dists/{bookworm,trixie}/main/binary-amd64/Packages.xz ; https://archive.ubuntu.com/ubuntu/dists/noble/{main,universe}/binary-amd64/Packages.xz
- Ubuntu image manifests: https://releases.ubuntu.com/noble/ubuntu-24.04.3-live-server-amd64.manifest ; https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.manifest ; https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.manifest
- Bash installers: https://raw.githubusercontent.com/rust-lang/rustup/master/rustup-init.sh ; https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh ; https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh ; https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh
- Node: https://nodejs.org/docs/latest-v18.x/api/readline.html ; https://endoflife.date/api/nodejs.json ; npm registry `https://registry.npmjs.org/<package>/latest` for `@clack/prompts`, `inquirer`, `@inquirer/prompts`, `prompts`, `enquirer`
- Detection: https://manpages.debian.org/trixie/manpages/proc_meminfo.5.en.html ; https://docs.kernel.org/admin-guide/cgroup-v2.html ; https://manpages.debian.org/trixie/coreutils/nproc.1.en.html ; https://manpages.debian.org/trixie/iproute2/ip-route.8.en.html , .../ss.8.en.html ; https://manpages.debian.org/trixie/hostname/hostname.1.en.html ; https://manpages.debian.org/trixie/systemd/systemd-detect-virt.1.en.html ; https://manpages.debian.org/trixie/ufw/ufw.8.en.html ; https://documentation.ubuntu.com/server/how-to/security/firewalls/
- WSL: https://devblogs.microsoft.com/commandline/systemd-support-is-now-available-in-wsl/ ; https://learn.microsoft.com/en-us/windows/wsl/wsl-config

**Project baseline (read directly):** `readme.md`, `main.sh`, `src/common/{checks,env,prompts,flags,setup}.sh`, `variables.example.json`, `src/setup/common/loadVariables.js`, `src/setup/download/download_packages.sh`, `src/setup/download/json/curseforge_variables.example.json`, `package.json`.
