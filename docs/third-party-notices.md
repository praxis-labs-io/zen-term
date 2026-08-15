# Third-party notices: re-probe after a ghostty pin move

`Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md` lists what ZenTerm actually ships. **What gets linked is a
property of the build, not of `build.zig.zon`**, so the pin moving is what makes this file
wrong. Run this pass whenever `vendor/ghostty` changes, and fold any difference into the
notices before tagging.

Three rules learned the hard way:

- **Probe the linked executable, not `libghostty-fat.a`.** The archive is a bag of object
  files the linker draws from selectively: it is ~141 MB against a ~16 MB binary. The
  original audit probed the archive and still under-counted the shipped set by eight
  libraries, because it went looking for names it already expected.
- **Symbols cannot see data.** Fonts are embedded bytes with no symbols, so a symbol probe
  misses every one of them. That gap is why v0.1.0 shipped three unattributed fonts while
  the bundle contained zero `.ttf` files and looked clean.
- **Neither probe sees a plain file.** Artwork, themes, shaders, and shell integration are
  copied into the resource bundle whole, and a symbol or sfnt scan walks straight past them.
  That is how 463 iTerm2 themes and a vendored `bash-preexec.sh` shipped unattributed, and
  why section 4 runs whenever a resource lands, not only when the pin moves.

## 1. Build what you are going to probe

```sh
swift build -c release
```

## 2. Libraries: probe the linked binary

```sh
nm -U .build/release/ZenTerm | awk '$2=="T"||$2=="t"{ $1=""; $2=""; print }' | c++filt > /tmp/defined.txt
wc -l < /tmp/defined.txt   # ~13k at the v1.3.1 pin

for p in google_breakpad simdutf glslang spirv_cross ImGui "utf8::" "hwy::" \
         FT_ onig_ png_ sentry_ wuffs inflate libintl mpack; do
    printf '%-18s %s\n' "$p" "$(grep -ci "$p" /tmp/defined.txt)"
done
```

Read the counts against the table in `Sources/ZenTerm/Resources/THIRD-PARTY-NOTICES.md`. A library that goes to
zero has left the build and its notice should go with it (`mpack` is the example: it sits in
the archive but the linker drops it, so it is deliberately absent from the notices). A new
name that appears owes a notice.

`libintl` must stay at zero. `bin/build-ghosttykit` builds ghostty with `-Di18n=false`, so
nothing references the GNU libintl it bundles on Apple platforms (Apple's libc omits it).
`SharedDeps.zig` still links the archive, but with no references the release linker dead-strips
it, so it leaves the shipped binary (the same mechanism that drops `mpack`). That is what keeps
this closed-source app clear of libintl's LGPL-2.1 static-linking relink obligation, which
attribution alone does not discharge. `bin/package-app` runs this same probe on the
linked binary and refuses to package a build where libintl survived, so a stale GhosttyKit
cannot ship the violation with the notice already deleted. A nonzero count means i18n came back
on: the flag was dropped, or ghostty started pulling libintl another way, and the obligation
returned with it.

Disabling i18n also turns off ghostty's macOS locale canonicalization, so a non-English macOS
user's child shell gets a non-canonical `LANGUAGE` (e.g. `zh-Hant-TW` rather than `zh_TW`);
`LANG` is unaffected. That is an accepted tradeoff for staying off libintl at launch.
Restoring it would mean dynamic-linking libintl or reimplementing the mapping.

C++ libraries mangle their symbols, so demangle through `c++filt` before matching or they
undercount to zero. Watch for the reverse too: a case-insensitive `gettext` grep matches
`ImGui::GetTextLineHeight`, which is not gettext.

## 3. Fonts: parse the executable for sfnt table directories

Symbols will not find these. Scan for font headers and read their name tables:

```sh
python3 - <<'EOF'
import struct
data = open(".build/release/ZenTerm", "rb").read()
seen = set()
for magic in (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf"):
    i = data.find(magic)
    while i >= 0:
        n = struct.unpack(">H", data[i + 4 : i + 6])[0]
        if 1 <= n <= 64:
            tables = {}
            for k in range(n):
                rec = i + 12 + k * 16
                tag = data[rec : rec + 4]
                if len(tag) == 4 and all(0x20 <= b < 0x7F for b in tag):
                    tables[tag] = struct.unpack(">II", data[rec + 8 : rec + 16])
            # 'head' rather than 'glyf'/'CFF ', or bitmap and color fonts slip through.
            if b"name" in tables and b"head" in tables:
                off, _ = tables[b"name"]
                base = i + off
                count, str_off = struct.unpack(">HH", data[base + 2 : base + 6])
                for k in range(count):
                    rec = base + 6 + k * 12
                    plat, _, _, nid, slen, soff = struct.unpack(">HHHHHH", data[rec : rec + 12])
                    if nid in (0, 1):  # copyright, family
                        s = data[base + str_off + soff :][:slen]
                        try:
                            t = s.decode("utf-16-be") if plat == 3 else s.decode("latin-1")
                        except UnicodeDecodeError:
                            continue
                        if t not in seen:
                            seen.add(t)
                            print(f"0x{i:x}  {t}")
        i = data.find(magic, i + 1)
EOF
```

At the `v1.3.1` pin this reports exactly three fonts: JetBrains Mono (variable regular and
variable italic) and Symbols Nerd Font. More than three means ghostty started embedding
something new and it needs an OFL/MIT notice.

## 4. Bundled resources: list the files

Symbols and sfnt headers both miss these, so the probe is a directory listing. It collapses
ghostty's shell-integration and themes trees to one line each; everything else is named.

```sh
find Sources -path '*/Resources/*' -type f -o -name '*.glsl' \
    | sed 's|\(ghostty-resources/ghostty/[a-z-]*\)/.*|\1/…|' | sort -u
```

Every file here owes a notice unless we authored it, and so does artwork with no file of its
own: the app icon is Lucide's `origami` pasted into `icon/make-icon.swift` as SVG path data.
Read the list against the Icons, Themes, Shaders, and Shell integration sections of the
notices. Ghostty's terminfo is ghostty's own and rides its MIT entry; `bash-preexec.sh` sits
inside the same tree and does not.

## 5. Regenerate and diff

License texts come from the Zig dependency cache (`~/.cache/zig/p/<hash>/`), keyed by the
hashes in `vendor/ghostty/pkg/*/build.zig.zon`. Copy them verbatim: do not retype or
summarize a license. Check the copyright years moved too, not just the terms.

Section 4's resources are not in that cache. The themes tarball ghostty pins carries no
license file at all, so take those texts from the upstream repository instead.

One exception to "verbatim": decode any stray HTML entities. Breakpad's vendored copy of the
APSL block carries `&apos;` where the published license has an apostrophe; a `grep -n '&[a-z]*;'`
over the result catches these, and they should read as the plain character.

## 6. Confirm the notices still open

The file is a SwiftPM resource loaded via `Bundle.module`, so it resolves in both a dev and a
packaged build. **zen-term → Acknowledgements…** (under About) opens it in its own themed,
scrollable window (the markdown scaffolding is stripped by `Acknowledgements.plainText`; the
license bodies pass through verbatim). Separately, **About zen-term** shows the version:

- [ ] `bin/run`, then **zen-term → Acknowledgements…**. The window opens, themed from
      `Theme.current` (background and text follow the active theme, not the system appearance),
      and scrolls the full notices. Reopening it refocuses the same window rather than stacking
      a second. This is the dev path, resolving out of `.build`.
- [ ] **zen-term → About zen-term** reads `AppVersion.current`, not a blank version.
- [ ] `bin/package-app`, then the same two menu items on the packaged app. Acknowledgements
      resolves out of the app's resource bundle, About reads the tag stamp (e.g.
      `0.1.0+6 (133)`), and `ls "$HOME/Applications/ZenTerm Dev.app/Contents/Resources/THIRD-PARTY-NOTICES.md"`
      confirms the plainly-visible top-level copy is there too (bare `bin/package-app`
      builds the dev variant).
