---
name: release
description: "Cut a Ducko release: update CHANGELOG.md on main, then push the X.Y.Z tag that triggers the release.yml CI workflow (build, sign, notarize, DMG, Sparkle appcast, GitHub Release). Use when the user asks to \"cut a release\", \"publish a new version\", \"prepare a release\", \"tag a release\", or \"ship it\"."
---

# Release

Cut a release straight from `main`: update the changelog, then push an `X.Y.Z` tag. CI does the build — the tag triggers `.github/workflows/release.yml`, which builds, signs, notarizes, packages a DMG, regenerates the Sparkle appcast, and publishes a GitHub Release whose body comes from `CHANGELOG.md`. Signing and Sparkle secrets are already configured in CI. Releases are built exclusively via GitHub Actions — never locally.

There is no version file to bump — the marketing version comes from the tag, and `CHANGELOG.md` is the only prep artifact (`version.env` holds names, not the version; the build number is the commit count).

## Step 1: Determine the version

If the user did not give one, infer the next `X.Y.Z` from the latest tag and propose a patch/minor/major bump, then confirm:

```bash
git tag --sort=-v:refname | head -1
```

## Step 2: Update the changelog

Make sure `main` is clean and current (`git checkout main && git pull origin main`). `CHANGELOG.md` keeps a running `## [Unreleased]` section, so a release completes that section and then promotes it to a version heading.

**Scope: user-facing only, framed as a net delta.** `CHANGELOG.md` becomes the GitHub Release notes and the Sparkle update notes, so it must describe only what a user experiences between releases. Before promoting, review every `[Unreleased]` entry and:

- **Drop non-user changes.** CI, scripts, skills, tests, and refactors don't ship to users. `DuckoCLI`-only changes belong only when the CLI is part of what the release ships.
- **State the net delta from the last released version, not the development history.** The `[Unreleased]` section accumulates commit-by-commit, so it collects entries that only make sense relative to an intermediate unreleased build (e.g. "no longer does X" / "removed the Y glitch" where X or the Y bug never shipped). Rewrite or drop those so each entry reads as a change the previous release's users will actually notice.
- **Check each entry's subject against the last tag, don't just scan the phrasing.** A positively-phrased entry hides the same trap: a fix for a feature that arrived in this same cycle reads like something users would notice, but nobody on the previous release ever hit that bug. For every entry, confirm the thing it changes or fixes existed at the last tag — `git show <last-tag>:<path>`, plus `git log --follow -- <path>` when the file moved. When it did not, fold the entry into whatever introduced the feature, or drop it. One entry per net user-visible change, not one per commit.
- **Describe the experience, not the mechanism.** "Rooms remember their bookmark autojoin flag" is what a user sees; the stanza or storage detail belongs in the commit, not the release notes.

1. **Complete `[Unreleased]` via `/update-changelog`.** Run it to capture anything missing, then double-check completeness against `git log <last-tag>..HEAD --oneline` — that range always includes the prior `Update appcast.xml for <last>` commit (CI pushes it to `main` after the tag) as noise, and real changes can land *after* it, so don't stop scanning there.
2. **Promote** by inserting the version heading (`## [X.Y.Z] - YYYY-MM-DD`, today's date) under the kept-empty `## [Unreleased]` heading so the accumulated entries fall under the new version, add the `[X.Y.Z]: https://github.com/ducko-im/ducko/compare/<last-tag>...X.Y.Z` link reference (`.../releases/tag/X.Y.Z` for the first release), and repoint `[Unreleased]` to `compare/X.Y.Z...HEAD` (mirror the previous `Prepare release X.Y.Z` commit's changelog diff). `release.yml` extracts this version section as the GitHub Release notes.

## Step 3: Commit and push to main

```bash
git add CHANGELOG.md
git commit -m "Prepare release X.Y.Z"
git push origin main
```

The tag must land on a `main` commit: `release.yml` signs only commits reachable from `origin/main`, and it reads `CHANGELOG.md` at the tagged commit.

## Step 4: Tag and trigger the release

Dispatch a dry run and wait for it to pass before tagging when the signing or packaging inputs changed since the last tag:

```bash
git diff --stat <last-tag>..HEAD -- Package.swift Resources/Entitlements.plist Scripts/package_app.sh Scripts/create_dmg.sh Scripts/release.sh .github/workflows/release.yml
```

**Skip** the dry run when that diff is empty. It is the only check that signs, notarizes, and staples the real arm64 build, since CI's release smoke test stubs those tools:

```bash
gh workflow run release.yml --ref main -f version=X.Y.Z -f dry_run=true
gh run list --workflow release.yml --limit 1   # run ID, when the dispatch prints no URL
gh run watch <run-id> --exit-status
```

If the dry run fails, fix the cause on `main`, push, and dispatch again. Tag only after a dry run passes. A passing dry run uploads its artifacts for inspection.

Tag the latest `main` commit (the changelog commit, or a later dry-run fix) and push the tag — this is what starts CI:

```bash
git tag -a X.Y.Z -m "X.Y.Z"
git push origin X.Y.Z
```

`release.yml` then builds, signs, notarizes, generates the appcast, creates the `X.Y.Z` GitHub Release (notes from the changelog section), and commits the updated `appcast.xml` back to `main`.

## Step 5: Finish

```bash
git pull origin main    # pick up the appcast commit CI pushed
gh release view X.Y.Z   # verify the Release and its assets
gh run list --commit "$(git rev-parse X.Y.Z^{commit})"   # every workflow on the tagged commit
```

`ci.yml` runs on the tagged commit from its push to `main`, separately from `release.yml`, so a passing release run does not cover it. Report the release as done only once both have passed, waiting on an unfinished run with `gh run watch <run-id> --exit-status`. When the CI run failed, name the failure and fix it on `main`.

## Notes

- Reserve each `X.Y.Z` for one set of artifacts — re-tagging a published version reuses the Release and appcast URLs for different content.
- The Sparkle EdDSA private key lives in the login Keychain under `generate_keys --account ducko` and is backed up in 1Password. `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account ducko -p` must print the `SUPublicEDKey` in `Scripts/package_app.sh`. GitHub cannot show the `SPARKLE_PRIVATE_KEY` secret, so when its contents are in doubt, re-set it from that key (`generate_keys --account ducko -x <file>`, then `gh secret set SPARKLE_PRIVATE_KEY < <file>` and delete the file) rather than generating a new pair. A mismatched pair still publishes a release, but every later update fails signature verification for its users.
- If CI is unavailable, see [references/local-release.md](references/local-release.md) for the manual release procedure.
