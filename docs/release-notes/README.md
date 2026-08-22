# Release notes

Curated notes for each public release, one file per version (`vX.Y.Z.md`). This
is the source; the file becomes the GitHub release body verbatim.

Write the notes here, then cut the release pointed at the file:

    bin/release --notes-file docs/release-notes/vX.Y.Z.md

Without `--notes-file`, `bin/release` drops you into `$EDITOR` on a raw git-log
scaffold. That scaffold is a starting point, not the notes: the commit subjects
are written for the person who wrote the patch, and the release is read by the
person downloading it.

Voice is governed by `../brand-voice.md`, under the "Release notes" surface:
curated, not a git log. State what changed, name the actor, no em-dashes, no
hype, no adverbs.

## One edit was made to shipped notes

Notes are per version and are never edited once published. v1.0.0 made a single
deliberate exception: every link into `zen-term/zen-term-releases` was repointed at
`praxis-labs-io/zen-term`. That repo is being deleted, and two of those links (the
onboarding and config references in v0.1.0) had no redirect target at all. The rule
exists to stop history being rewritten for cosmetics, not to preserve links to a repo
we removed ourselves. Nothing else in those files changed.
