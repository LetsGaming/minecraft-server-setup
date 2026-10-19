// scripts/update/lib/versions.js
//
// Choosing among the builds Modrinth lists for a mod.

/** release is what the author recommends; beta and alpha only when nothing better exists. */
const TYPE_RANK = { release: 0, beta: 1, alpha: 2 };

const rankOf = (version) => TYPE_RANK[version?.version_type] ?? 0;
const newestFirst = (a, b) => new Date(b.date_published) - new Date(a.date_published);

/**
 * The build to install for a game version and loader: the newest release, or
 * when the mod has none, the newest beta, or failing that the newest alpha.
 *
 * @param {Array<object>} versions  a Modrinth version list
 * @returns {object|null}
 */
function pickVersion(versions, mcVersion, modLoader) {
  const compatible = (Array.isArray(versions) ? versions : []).filter(
    (v) => v.game_versions?.includes(mcVersion) && v.loaders?.includes(modLoader),
  );
  compatible.sort((a, b) => rankOf(a) - rankOf(b) || newestFirst(a, b));
  return compatible[0] ?? null;
}

module.exports = { pickVersion, rankOf, newestFirst };
