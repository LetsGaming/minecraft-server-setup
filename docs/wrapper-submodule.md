# The API wrapper submodule

`src/scripts/api-server` is the API wrapper
([minecraft-server-api](https://github.com/LetsGaming/minecraft-server-api)) as
a git submodule. An operator who updates the suite gets the wrapper commit the
pointer names, not the wrapper's latest, so the pointer is a release decision
and moves by hand.

## Order of a contract change

The bot, the wrapper and this repo are released by different people on
different machines, so a change that touches the wrapper's HTTP surface lands in
a fixed order:

1. **Wrapper.** The route and its response schema change, `openapi.json` is
   regenerated, its tests and changelog are updated, and a new manifest feature
   version is declared if the shape changed. The wrapper's own `bot contract`
   workflow checks the bot's default branch against it.
2. **This repo.** Bump the pointer (below). The `Wrapper contract` workflow
   builds that wrapper commit and runs the bot's `e2e:contract` against it.
3. **Bot.** Vendors the new `openapi.json` (`npm run wire:sync`), adapts its
   callers and raises what it expects of the wrapper.

The wrapper ships first and the bot last. Within a major version the wrapper
keeps serving the old shape next to the new one for one minor release, and the
bot negotiates through the feature versions in `GET /manifest`, which is why an
operator can update the two on separate days. If a change cannot keep that
window, the three pull requests link each other and merge together.

## Bumping the pointer

```bash
git submodule update --init src/scripts/api-server
git -C src/scripts/api-server fetch origin
git -C src/scripts/api-server log --oneline HEAD..origin/main
```

Read that list and the wrapper's `CHANGELOG.md` before moving. Then:

```bash
git -C src/scripts/api-server checkout <commit>
git add src/scripts/api-server
git commit -m "Bump the API wrapper to <short sha>: <what changed for operators>"
```

Pin a commit the wrapper's own CI has passed, ideally a tagged release, never a
branch tip you have not looked at. Put the wrapper commits that matter to
operators in the message; this repo's changelog gets an entry when the bump
changes what an operator sees.

## What checks the pointer

`.github/workflows/wrapper-contract.yml` runs on every change to the pointer. It
checks out the suite with its submodule, builds the pinned wrapper, builds the
bot's default branch and runs the bot's `e2e:contract` against the pinned
checkout with `E2E_REQUIRE_SUDO=1`, so the routes that run suite scripts are
exercised for real. The workflow files cannot be run locally; to reproduce the
check by hand:

```bash
# in the suite checkout
(cd src/scripts/api-server && npm ci && npm run build)
# in a minecraft-bot checkout, built with npm ci && npm run build
WRAPPER_DIR=<suite>/src/scripts/api-server E2E_REQUIRE_SUDO=1 npm run e2e:contract
```

Without passwordless `sudo -n -u <your user>` the script routes are only checked
for their failure shape and reported as unverified; drop `E2E_REQUIRE_SUDO` to
accept that locally.

A red run has two readings. If the bot's expectations moved ahead of the
pointer, bump the pointer to a wrapper that serves them. If the pinned wrapper
regressed, fix it in the wrapper repo and bump again.

## What an operator sees

Operators do not need to know wrapper version numbers. The bot reads
`GET /manifest` at startup and reports which features the installed wrapper
lacks and what each costs. Documentation names those features, not versions.
