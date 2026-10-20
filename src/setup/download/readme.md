# Download scripts

Helpers that `main.sh` runs during setup. They are not meant to be run by hand.

- `download_packages.sh` installs the system packages (`curl`, `screen`, `unzip`, `nodejs`, `npm`, `cron`, `rsync`, `zstd`, `jq`, `acl`) with `apt` and runs `npm ci --omit=dev`.
- `download_modpack.js` downloads the CurseForge server pack to `temp/server-pack.zip`. It reads `pack_id` and `api_key` from `json/curseforge_variables.json` (copy `json/curseforge_variables.example.json`) and exits with an error if either is missing or `none`.
- `download_mods.js` downloads additional mods from Modrinth into `temp/mods`. The mod IDs come from `json/modrinth_variables.json`; the modpack setup runs it after the modpack download.

Node.js 18 or newer is required (`engines` in the root `package.json`).
