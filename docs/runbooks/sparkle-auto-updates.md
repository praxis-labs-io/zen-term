# Sparkle Auto-Updates Runbook (ZEN-118)

How in-app updates work, and the manual verification a unit test can't reach
(signing, notarization, and a real appcast round-trip need a Mac with the
Developer ID cert). Automated coverage: the notes-column budget and the appcast
bullet parsing are in `UpdateCardTests`; the card's layout, color, and motion are
here, by eye.

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

Steps 1–2 also run green from an ad-hoc `bin/package-app` (no cert needed); the
rest need a real signed release.

- [ ] **1. Dev launch (the rpath check).** `swift run ZenTerm` launches and behaves
      normally. This is the step most likely to break, because the binary links
      `@rpath/Sparkle.framework`; SwiftPM copies the framework beside the dev binary,
      so `@loader_path` resolves it. `swift test` links it too.
- [ ] **2. Packaged, nested code signs.** `bin/package-app`, then
      `codesign --verify --strict --deep --verbose=2 ~/Applications/ZenTerm.app`
      passes with the nested Sparkle `Autoupdate`, `Updater.app`, and framework all
      validated. `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices` is
      absent (dropped: sandbox-only).
- [ ] **3. The card appears.** Point `SUFeedURL` at a local test appcast advertising
      a `sparkle:version` above HEAD's build number. On launch the card appears
      top-right: origami badge accent-tinted, the notes as bullets, three buttons.
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
