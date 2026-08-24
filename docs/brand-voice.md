# ZenTerm brand and voice

How ZenTerm describes itself, and how its copy sounds. This governs every word a
person outside the project reads: the marketing site, the release repo, these
docs, release notes, and the copy inside the app.

This file is mirrored into `zen-term` and `zen-term-website`. Edit it here and
copy it out. Anything else drifts.

---

## What ZenTerm is

**A modern terminal for developers.**

The headline form, used by the site's `SITE_HEADLINE` and its OG image:

> A terminal, built to the pixel.

The longer version, when a sentence isn't enough:

> ZenTerm is a modern macOS terminal for developers: tiled panes, drawers, and
> tool floats, orchestrated into workspaces a keystroke away, with a
> keyboard-first way through all of it. Terminal emulation, font handling, and
> rendering come from libghostty, the core the Ghostty project publishes so
> other terminals can be built on a shared engine.

"A dev-first terminal" survives as an eyebrow and a subtitle, above the headline
or under it. It is no longer the primary form: it says who the product is for
and leaves what it is unstated.

The purpose is polish and functionality for terminal devs of all kinds.

## Who it's for

Terminal devs of all kinds. The product leans toward people who live in the
terminal and people running agents there, but the lean is a lean. It is not the
identity, and it is not the audience.

**Do not write copy that:**

- makes agentic coding the premise ("the terminal for the agentic era")
- addresses the reader as a newcomer that AI dragged into a terminal
- treats terminal-first developers as a niche inside an AI story

Agents are one thing people run. They get their share of the copy, not the frame.

## How we credit the core

ZenTerm runs on a libghostty core and credits it plainly, with a link to
ghostty.org wherever the credit appears. Ghostty publishes libghostty so other
terminals can be built on a shared engine, and ZenTerm is one of them. Say that,
and say it in Ghostty's own terms: libghostty handles terminal emulation, font
handling, and rendering.

The credit is a spec line. It goes below the claim, in a comparison, or in the
docs. It is never the headline, never the opening premise, and never framed so
ZenTerm reads as an accessory to it. Don't overclaim what ZenTerm renders
itself, and don't hand away what it does own: the layout engine, the input
routing, scroll mode, the theming, and the chrome.

---

## Voice

Plain language. No pomp and circumstance. Short declarative sentences. Say what
the thing does and stop.

Five heuristics carry most of it:

1. **A sentence states a fact.** No setup, no metaphor, no wind-up. If the first
   half of the sentence exists to make the second half land, cut the first half.
2. **A heading names an outcome**, usually verb-first. "Split a pane without
   leaving home row" over "Panes", and over "Supercharge your workflow".
3. **Specificity replaces description.** A number beats an adjective every time.
   "17 built-in themes" does work that "beautifully themed" does not. Write
   numbers as digits, including under ten: a digit is what gets scanned, and a
   spelled-out number reads as decoration.
4. **A button is a verb.** "Download". "Quit". "Retry". Never "Get started for
   free today".
5. **Confidence lives in the claim, not the adjectives.** If the claim is true,
   it survives having its adjectives removed. If it doesn't survive, it wasn't a
   claim.

Read the rules below as the enforceable form of these five.

---

## The rules

Mechanical and checkable. A reviewer should be able to fail copy on these.

1. **No em-dashes.** Anywhere, on any surface, including quotes of other people's
   copy. Use a colon, a period, a comma, or split the sentence. Plenty of good
   writing uses them, which is exactly why this drifts back: the rule is ours and
   it outranks any outside example. This file contains none, and a grep for the
   character should keep returning nothing. **No dot spacers either** (a middle
   dot `·` between a title and a qualifier): use a colon, e.g. a zoomed panel
   header reads "Terminal pane: Focus Mode".

   **Scope: prose a user reads.** Code comments and `NSLog` strings are out of it
   ("I do not care about comments"), so don't sweep `Sources/` for the character.
   `docs/config/*` stays **in** scope, because users open those files. Everything
   governed takes the grep as its test, not a judgment call about whether the dash
   "joins two label halves": a doc title with an em-dash has already been ruled a
   violation and fixed to a colon.
2. **No hype words.** seamless, powerful, beautiful, blazing, effortless,
   delightful, magical, just works, game-changer, unleash, supercharge. The
   product demonstrates these or it doesn't have them.
3. **No adverbs.** really, just, simply, actually, literally, genuinely, truly.
   They add emphasis and no meaning.
4. **Active voice, and name the actor.** "Collisions are reported" hides who.
   "The app tells you" doesn't. Inanimate things don't act: a complaint doesn't
   become a fix, a decision doesn't emerge.
5. **No "not X, it's Y" contrasts.** State Y. This extends to any contrast whose
   alternative nobody proposed: "it describes what exists rather than what was
   planned" invents an assumption in order to defeat it. The test is whether a
   reader would have made that assumption unprompted. "Moves by direction rather
   than by order" passes, because order-based movement is what other terminals
   do. If the alternative is a strawman, state the claim alone.
6. **No fragments for drama.** "One window, one pane, your shell. That's it."
   A fragment used for density is fine and often better: a list of noun phrases
   reads as a spec sheet, which is what someone scanning wants. The failing kind
   is the one that exists for a beat of emphasis.
7. **No rhetorical questions**, no "Here's the thing," no "Let that sink in."
8. **No lazy extremes.** every, always, never, nobody. Use the specific number.
9. **Vary sentence length.** Plain does not mean staccato.
10. **Second person.** "You" beats "users" and "people."
11. **No designed final clauses.** A paragraph that resolves on a balanced
    closing beat reads as composed rather than written, and it is the single
    clearest sign copy was drafted by a machine. "So neither one can tell you
    something the other contradicts." "So nothing you did not write appears
    here." "Which makes the first open cold and every reopen instant." Each
    states a real fact wearing a cadence. Say the fact and start a new sentence.
    The check: read only the last clause of each paragraph in a row. If they
    sound like a set, cut them.
12. **No writerly constructions where a plain verb exists.** "A cursor that
    knows where it is" is a cursor that moves by direction. "Summons a float on
    a chord" is a chord that opens a float. "Reads the app to someone opening it
    for the first time" walks through the app. The literal version is the one
    that ships.
13. **Contractions are fine.** "Doesn't", "you're", "it's". Removing them does
    not add authority, it adds starch.
14. **Say what the product is, and name what it is built on with confidence.**
    Both, in that order. "Built on libghostty" is a credential: the core
    underneath is Ghostty's, that is worth knowing at first glance, and it
    belongs high on the page in a spec position, linked to ghostty.org. What
    never ships is the same fact in disclaimer form. "libghostty renders the
    text and runs the shell; ZenTerm is everything around that" defines the
    product as a remainder and reads as an accessory. A credential is something
    ZenTerm has. A remainder is something it lacks. Banned constructions:
    "everything around that", "on top of that", "adds the rest", and any
    sentence where ZenTerm is what is left over. The test is whether the
    sentence names something ZenTerm owns: the layout engine, the input
    routing, scroll mode, the theming, the chrome.
15. **Positioning by contrast is rule 5 at document scale.** A page whose
    premise is a comparison fails the same way a sentence does. Open with the
    claim, and let the contrast come later, if at all.

---

## How we talk about other projects

Name the incumbent. Describe what it does well, in its own terms. Then state
what ours does differently. Three steps, in that order.

Never make a claim whose only content is that someone else lacks something. "The
only terminal with real panes" is not a claim about ZenTerm. "Panes tile, and
your shells keep running as you rearrange them" is.

The site's comparison section is the standard:

> "No knock on the classics. ZenTerm makes different bets, and this is where
> they show up."

It concedes the ground, names the bets as bets, and lets a table carry the rest.
The table has rows ZenTerm does not win, which is what makes the rows it does
win worth reading. Copy that reads as a put-down of iTerm2, Warp, Kitty,
Terminal.app, or Ghostty does not ship.

The same rule governs the rest of the suite. zen-linear began as a fork of
linear-tui, zen-octo took its config shape from gh-dash, and zen-review took
ideas from hunk and tuicr. Each of those debts is stated in its own repo, in its
own sentences, above the first capability claim or in an Acknowledgments
section. A debt stated in a subordinate clause under a claim about doing better
is not a credit.

---

## What our copy already gets right

These are real strings from the app. The doctrine is descriptive: this is already
how ZenTerm sounds at its best, and the rest should catch up.

**Zero hype.** There is not one instance of "seamless," "powerful," "beautiful,"
or "just works" in the app's user-facing copy. The nearest thing to a superlative
is `"Applies instantly"`, and that's a factual claim that distinguishes the row
from its `(new tabs)` neighbors. This is the most distinctive thing about the
copy. Protect it.

**Confirmations state the consequence. They never ask if you're sure.** There is
no "Are you sure?" anywhere in the codebase, and there should never be one.

> "Closing this pane will stop the process running in it."
> "Quitting will close 4 tabs in 2 windows and stop everything running in them."

The button names the verb ("Quit", "Close", "Delete"), never "OK". The copy says
what dies. It does not ask the user to introspect.

**Nothing fails silently.** When an action does nothing, say so:

> "No pane left to focus"
> "Exit Focus Mode (⌘F) to split."

**Errors name the place and the fix.**

> "This needs a Git repository. Run `git init` here, or open a folder that has one."
> "The bottom drawer failed to launch. Open it again to retry."
> "Failed to write open-gitdash to the config file: …"

Never leave the reader with advice they can't follow.

**Empty states: state, imperative, payoff.**

> "No tool floats yet. Add one to get a toolbar button and a shortcut."
> "No workspaces yet. Add one to launch a folder with its own layout from ⌘P."

**Brevity is measured, not felt.** The toast copy fits a 236pt budget, and
"went to" was chosen over a spelled-out phrase because it costs ~30pt less. Copy
that doesn't fit its container is broken copy, so measure it against the real
font and column.

**The truest line we've written is buried in a config comment:**

> "This list is deliberate and hand-curated. zen-term does NOT scan any directory."

That's the thesis. It says what the product believes without one adjective. Copy
of this quality belongs on the site, not only in a reference file.

---

## By surface

### Marketing site

Headings name an outcome. Body is one or two sentences. Every claim is
demonstrable in the app today. No roadmap in the present tense.

### In-app copy

The strictest surface, because it is read mid-task by someone who wants to be
doing something else.

- **Titles: Title Case.** "Terminal Didn't Start", "Close Pane", "Quit ZenTerm".
- **Body: sentence case**, ending in a period.
- **Buttons: the verb.** "Quit", "Retry", "Delete", "Save".
- Measure it against its container before shipping it.

### Errors and confirmations

Say what happened, where, and what to do next. A user should never have to guess
which file, which tool, or which action.

### Docs and references

Declarative and annotated. `docs/config/config` is the model: every value is the
default, every key carries a one-line note, and it says plainly what happens on a
bad line. Keep release-notes voice out of reference files. "The old built-in ⌘G
lazygit" means nothing to someone who never used a prior version.

### Release notes

Curated, not a git log. The commit subjects become public: write them for the
person downloading, not for the person who wrote the patch.

---

## Vocabulary

One word per concept. The audit found four concepts with two or three words each.

Find is the one row where the two vocabularies deliberately differ, and the seam
below is why: every label a user reads says Find, every token they type says
`search`. `toggle_search`, `search_selection`, `search_next`, `search_previous`.

| Concept                               | Use                                                  | Not                                                        |
| ------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------- |
| The product                           | **ZenTerm**                                          | zen-term (that's the repo, the binary, and the config dir) |
| A tiled terminal region               | **pane**                                             | split (only ever a verb: "Split Horizontally")             |
| A saved folder + layout               | **workspace**                                        | project, repo                                              |
| A key combination                     | **shortcut** in UI, **chord** when precision matters | keybind (that's the config key name)                       |
| A floating tool                       | **tool float** first, **float** after                | tool                                                       |
| One pane or drawer filling the window | **Focus Mode**                                       | zoom, full screen                                          |
| The whole window filling the desktop  | **Fill Screen**                                      | full screen, fullscreen, maximize                          |
| Version control                       | **Git repository**, or **Git repo**                  | repo, git repository (lowercase)                           |
| The footer button row                 | **toolbar**                                          | dock (that's macOS's; the type name `ToggleDock` is code)  |
| Looking through the scrollback        | **Find** in UI, `search` in config                   | search in UI, scrollback search, find in config            |

Apostrophes: straight (`'`), matching the bulk of the codebase. Two form overlays
use curly (`’`) and should be reconciled.

### The seam: UI vocabulary vs config vocabulary

The product has two vocabularies. The UI says "Workspaces" and "shortcut". The
config file says `keybind = ` and speaks in snake_case action tokens.
`ConfigDiagnostic` deliberately speaks the config file's vocabulary, because it
names the token you grep for, and that reasoning is sound.

**The rule:** the config vocabulary wins only where the user is looking at the
config, and the token must be a word the product still uses. `toggle_repo_picker`
failed that test: a user could be shown "⌘P went to toggle_repo_picker in your
config" while every other surface said "Workspaces". It was renamed to
`toggle_workspace_picker`, and the old token still parses so an existing
binding keeps working.

Renaming a config token is a breaking change for anyone who has bound it, so it
needs a real deprecation, not a find-and-replace.

---

## Checklist

Before any copy ships:

- [ ] Any em-dash or dot spacer (`·`)? Replace it with a colon.
- [ ] Any hype word or adverb? Cut it.
- [ ] Read the last clause of each paragraph in a row. Do they sound like a set?
      Cut the cadence and state the fact.
- [ ] Any contrast whose alternative nobody would have assumed? State the claim
      alone.
- [ ] A spelled-out number where a digit would be scanned? Use the digit.
- [ ] Passive voice, or an object doing a human verb? Name the actor.
- [ ] "Not X, it's Y"? State Y.
- [ ] Fragments stacked for drama? Write sentences.
- [ ] Does it fit its container, measured in the real font?
- [ ] One word per concept, matching the table above?
- [ ] Does every error name the fix?
- [ ] Strip the adjectives. Is the claim still true and still worth making?
- [ ] Does the first sentence say what the product is, or only what it adds to
      something else? Say what it is.
- [ ] Is a dependency in the headline instead of a spec line? Move it down.
- [ ] Does any claim rest on another project lacking something? State what ours
      does.
