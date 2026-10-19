// scripts/update/lib/jabba.js
//
// Installing a JDK through Jabba. The candidate name comes from Jabba's remote
// index, so it is checked before it is used and handed to bash as an argument,
// never spliced into the command text.

const CANDIDATE_RE = /^[A-Za-z0-9._@+-]+$/;

/** Throws unless `candidate` looks like a Jabba JDK name such as "temurin@21.0.4". */
function assertJabbaCandidate(candidate) {
  if (typeof candidate !== "string" || !CANDIDATE_RE.test(candidate)) {
    throw new Error(`Refusing a JDK name that is not plain letters, digits and . _ @ + -: ${JSON.stringify(candidate)}`);
  }
  return candidate;
}

const INSTALL_SCRIPT = '. ~/.jabba/jabba.sh && jabba install "$1" && jabba use "$1"';

/** [file, args] for execFileSync that installs and activates a candidate. */
function jabbaInstallCommand(candidate) {
  assertJabbaCandidate(candidate);
  return ["bash", ["-c", INSTALL_SCRIPT, "_", candidate]];
}

module.exports = { assertJabbaCandidate, jabbaInstallCommand };
