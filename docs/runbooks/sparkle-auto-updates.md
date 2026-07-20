# Sparkle Auto-Updates Runbook (ZEN-118, ZEN-19, ZEN-20)

How in-app updates work, and the manual verification a unit test can't reach
(signing, notarization, and a real appcast round-trip need a Mac with the
Developer ID cert). Automated coverage: the notes-column budget and the appcast
bullet parsing are in `UpdateCardTests`; the config toggle, the command/chord
plumbing, and the palette entry are in `GeneralConfigParserTests`,
`KeybindParserTests`, and `CommandCatalogTests`; the card's layout, color, motion,
keycap, and the manual-check toasts are here, by eye.

## How it works

- **Sparkle keeps the plumbing, the chrome owns every pixel.** Sparkle fetches the
  appcast, verifies the EdDSA signature, downloads and installs. `ZenUpdateDriver`
  (an `SPUUserDriver`) routes each user-facing moment into one `UpdateCardView` in
  the top-right toast stack, which morphs in place: available → downloading →
  ready. There is no stock Sparkle window, so nothing follows `effectiveAppearance`
  instead of `Theme.current` (ZEN-27).
- **Feed:** `SUFeedURL` is `.../zen-term-releases/releases/latest/download/appcast.xml`.
  `bin/release` uploads a single-item `appcast.xml` beside each DMG, so `latest/`
  always resolves to the newest release. Sparkle only ever offers the newest item.
- **Inert in dev.** A `swift run` build has no `SUFeedURL`, so `UpdateController`
  never starts. Only a packaged app checks for updates (daily, `SUScheduledCheckInterval`).
- **The card never takes focus.** It is non-modal, like a sticky toast: its buttons
  are click-only, so terminal input is never gated behind it.
- **On-demand check (ZEN-20).** A "Check for Updates" command in the palette (Config
  group) runs a manual check. Unlike a scheduled one it reports its result even when
  nothing is found: a "You're on the latest" info toast, or a warning toast on failure
  (an update found still shows the card). It ships with **no default chord**: bind one
  with `keybind = check_for_updates=<chord>` and the update card's top-right keycap
  slot fills with that glyph (empty until then, since an unbound glyph would lie).
  The command is app-global (the updater is app-owned): it reaches `UpdateController`
  via `AppDelegate.route`, and a palette pick lands there too through
  `WindowController.onAppGlobalCommand`, the same seam that makes Reload Config work
  from the palette.
- **Off switch (ZEN-19).** Settings → General → Updates → "Check for updates in the background"
  drives Sparkle's automatic-check schedule (`automatic-update-checks` in the config,
  on by default). It applies live: `AppDelegate` re-points Sparkle on `.configDidChange`.
  Inert in dev (no feed), like everything else here.

## One-time setup (Drew's machine)

The EdDSA signing key lives in the login keychain. Generate it once:

```
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It prints the `SUPublicEDKey` that is already baked into `bin/package-app`'s
Info.plist. If the key is ever regenerated, that plist value must change to match,
or installed copies reject the update's signature.

## The known one-time gap

The first Sparkle-enabled release cannot auto-update anyone: updating *from* a
build means that build shipped with Sparkle, and the ones before this did not. That
first hop is a manual DMG download. Onboarding says so.

## Verification

Steps 1–2 run green from an ad-hoc `bin/package-app` (no cert needed). The update
flow (3–6) also runs ad-hoc: build the release variant *below* the feed's latest and
the real, already-signed public release plays the part of "the update", so no scratch
release is needed. Only step 8 (cutting an actual release) needs the cert.

**Test-an-available-update recipe (no fake appcast, no signing).** The public appcast's
latest is build **152** (v0.2.2). Build a release-variant app that reports a *lower*
`CFBundleVersion`, so a check against the real feed sees 0.2.2 as an update:

```
bin/package-app --variant release --version 0.2.1 --build 100
open "$HOME/Applications/ZenTerm.app"
```

`--build` is testing-only (`bin/release` never passes it). Installing pulls and
verifies the genuine signed 0.2.2, so the download, EdDSA check, and relaunch are all
real. This is the shared setup for steps 3–6 and 11.

- [ ] **1. Dev launch (the rpath check).** `swift run ZenTerm` launches and behaves
      normally. This is the step most likely to break, because the binary links
      `@rpath/Sparkle.framework`; SwiftPM copies the framework beside the dev binary,
      so `@loader_path` resolves it. `swift test` links it too.
- [ ] **2. Packaged, nested code signs.** `bin/package-app`, then
      `codesign --verify --strict --deep --verbose=2 "$HOME/Applications/ZenTerm Dev.app"`
      passes with the nested Sparkle `Autoupdate`, `Updater.app`, and framework all
      validated. `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices` is
      absent (dropped: sandbox-only). Both variants embed and sign Sparkle identically;
      bare `bin/package-app` builds the dev variant (`ZenTerm Dev.app`).
- [ ] **3. The available card appears.** With the recipe build above, launch it: the
      card appears top-right against the real feed, origami badge accent-tinted, the
      release notes as bullets, three buttons ([Install] [Later] [Skip]) and "What's
      new". The header reads "ZenTerm 0.2.2 is available" over "You're on 0.2.1".
- [ ] **4. Install morphs in place.** Install → the card becomes a progress bar in
      place, then "Ready to install" with Relaunch. It never steals keys from the
      terminal and never takes first responder (type into a pane behind it while
      it's up).
- [ ] **5. Skip / Later persistence.** Skip, then relaunch: no card. Later, then
      relaunch: the card returns.
- [ ] **6. Re-home on window close.** With a card up, close the window hosting it:
      it re-homes to the next key window rather than vanishing mid-flow.
- [ ] **7. Theme swap.** Swap the theme with a card up (`⌘,` → Appearance): it
      recolors in place, no stale ink.
- [ ] **8. Real round-trip.** `bin/release` to a scratch tag, install the previous
      release, and confirm it sees and installs the new one over the real appcast,
      then relaunches into the new build.
- [ ] **9. Palette dispatch (dev is fine).** Open the command palette (⌘P) → Config:
      "Reload Config" and "Check for Updates" are both present. Pick **Reload Config**
      and confirm it re-reads the config (the previously-dead palette path, now fixed).
      "Check for Updates" shows no keycap (unbound by default).
- [ ] **10. Manual check result.** Run "Check for Updates" three ways: the recipe build
      (below the feed) shows the available card; a plain `--variant release` build (its
      build number is above the feed's 152) shows the "You're on the latest" info toast;
      an offline machine shows the "Couldn't check for updates" warning toast. A
      scheduled check in the same states stays silent.
- [ ] **11. Bound keycap.** Add `keybind = check_for_updates=cmd+opt+u` (any free
      chord), relaunch the recipe build, and trigger the available card (step 3): its
      top-right keycap slot now shows the glyph. Rebind or unbind with the card up (⌘, →
      Keybinds, or ⌘⌥R after a hand-edit) and the keycap tracks it.
- [ ] **12. Off switch.** Settings → General → Updates → set "Check for updates in the
      background" to Off. `automatic-update-checks = false` lands in the config, and
      Sparkle stops its scheduled checks (the manual command still works).
