# Release notes

One file per release, named for the tag, e.g. `1.0.0.md`. Its contents become the
GitHub Release body. (In repos that ship an updater they also become the Sparkle
appcast `<description>`; this repo has no appcast yet.)

**The file is optional.** A release with no matching file still gets a generated
body — title, "What changed", footer — and a committed file adds its prose
verbatim. What the publish job does refuse is an artifact whose
`RELEASE_NOTES.md` is missing or empty, and `release.yml` generates that on
every run, so the build fails first if it ever could not.

## How a release is numbered

This repo declares `semver` (INGREDIENTS.md, `## Versioning`). Shipyard's `release-version.sh`
derives the next tag from the newest `vX.Y.Z` tag and the one word in `<tag>/kind`: `major`,
`minor` or `patch`. Write `next/kind`, run `sh "$SHIPYARD_SCRIPTS/release-version.sh" --product
drydock`, rename `next/` to the tag it prints, then add `changes/`. A publishing run refuses a
release with no `kind` or no `changes/`.
