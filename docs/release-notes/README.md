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
