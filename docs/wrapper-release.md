# The API wrapper release

The API wrapper
([minecraft-server-api](https://github.com/LetsGaming/minecraft-server-api)) is
not part of this repository. `api-server-release.json` pins one of its releases:

```json
{
  "repository": "LetsGaming/minecraft-server-api",
  "version": "4.1.0",
  "sha256": "<sha256 of mc-api-server-4.1.0.tar.gz>"
}
```

A host that enables the wrapper (`API_SERVER.ENABLED` or `--api-server`)
downloads that release's `mc-api-server-<version>.tar.gz` from GitHub, checks it
against the sha256, unpacks it to `<target>/services/api-server/` and runs
`npm ci --omit=dev` there. The tarball is already built, so the host needs no
TypeScript and no dev dependencies. A host that never enables the wrapper never
downloads it. An operator who updates the suite gets the release the pin names,
not the wrapper's latest, so the pin is a release decision.

`src/setup/management/install_api_server.js` does the work for setup
(`create_api_server_service.js`, first install) and for `migrate.sh` (upgrade).
It stages and checks everything next to the install first; a failed download,
checksum, unpack or `npm ci` leaves the running wrapper as it was. A reinstall
keeps `api-server-config.json`, `.env`, `variables.txt` and `logs/`, and writes
`.release.json` with the installed version and checksum.

```bash
# What is installed, compared with the pin; changes nothing
node src/setup/management/install_api_server.js --dir <target>/services/api-server --check
# Offline host: install a tarball fetched elsewhere (still checked against the pin)
node src/setup/management/install_api_server.js --dir <target>/services/api-server --tarball mc-api-server-4.1.0.tar.gz
```

`MC_API_SERVER_RELEASE_BASE` replaces `https://github.com/<repository>/releases/download`
for a mirror; the checksum still has to match.

## Order of a contract change

The bot, the wrapper and this repo are released by different people on
different machines, so a change that touches the wrapper's HTTP surface lands in
a fixed order:

1. **Wrapper.** The route and its response schema change, `openapi.json` is
   regenerated, its tests and changelog are updated, and a new manifest feature
   version is declared if the shape changed. The wrapper's own `bot contract`
   workflow checks the bot's default branch against it. A tagged release
   publishes the tarball.
2. **This repo.** Bump the pin (below). The `Wrapper contract` workflow
   installs that release and runs the bot's `e2e:contract` against it.
3. **Bot.** Vendors the new `openapi.json` (`npm run wire:sync`), adapts its
   callers and raises what it expects of the wrapper.

The wrapper ships first and the bot last. Within a major version the wrapper
keeps serving the old shape next to the new one for one minor release, and the
bot negotiates through the feature versions in `GET /manifest`, which is why an
operator can update the two on separate days. If a change cannot keep that
window, the three pull requests link each other and merge together.

## Bumping the pin

Publishing a wrapper release opens the bump pull request here by itself (the
wrapper's `release` workflow, when its `SETUP_REPO_TOKEN` secret is set). By
hand:

```bash
v=4.1.0
curl -fsSLO "https://github.com/LetsGaming/minecraft-server-api/releases/download/v$v/mc-api-server-$v.tar.gz"
sha256sum "mc-api-server-$v.tar.gz"   # compare with the release's .sha256 asset
```

Put the version and checksum in `api-server-release.json` and commit. The
checksum is the tarball's: the first word of `mc-api-server-$v.tar.gz.sha256`,
or the digest GitHub's release page lists next to the `.tar.gz` (pasting it with
its `sha256:` prefix is fine). The digest listed next to the `.sha256` file is
that file's own checksum and fails the check.

```bash
git commit -am "chore: pin API wrapper $v: <what changed for operators>"
```

Read the wrapper's `CHANGELOG.md` for the releases in between before moving.
Put the wrapper changes that matter to operators in the message; this repo's
changelog gets an entry when the bump changes what an operator sees.

## What checks the pin

`.github/workflows/wrapper-contract.yml` runs on every change to the pin or to
the installer. It installs the pinned release with `install_api_server.js` the
way a host does, builds the bot's default branch and runs the bot's
`e2e:contract` against the install with `E2E_REQUIRE_SUDO=1`, so the routes that
run suite scripts are exercised for real. To reproduce the check by hand:

```bash
# in the suite checkout
node src/setup/management/install_api_server.js --dir /tmp/api-server
# in a minecraft-bot checkout, built with npm ci && npm run build
WRAPPER_DIR=/tmp/api-server E2E_REQUIRE_SUDO=1 npm run e2e:contract
```

Without passwordless `sudo -n -u <your user>` the script routes are only checked
for their failure shape and reported as unverified; drop `E2E_REQUIRE_SUDO` to
accept that locally.

A red run has two readings. If the bot's expectations moved ahead of the pin,
bump the pin to a release that serves them. If the pinned release regressed,
fix it in the wrapper repo, release again and bump.

## Coming from the submodule

The wrapper used to be a git submodule at `src/scripts/api-server/`.
After pulling, git may leave that folder behind as untracked files; it is no
longer used and can be deleted (`rm -rf src/scripts/api-server`). `migrate.sh`
says so when it finds it. The deployed wrapper from those days has no
`.release.json`; `migrate.sh` reports it as a copy from before releases and
replaces it with the pinned release.

## What an operator sees

Operators do not need to know wrapper version numbers. The bot reads
`GET /manifest` at startup and reports which features the installed wrapper
lacks and what each costs. Documentation names those features, not versions.
