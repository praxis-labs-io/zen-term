# ZenTerm brand and voice

How ZenTerm describes itself, and how its copy sounds. This governs every word a
person outside the project reads: the marketing site, the release repo, these
docs, release notes, and the copy inside the app.

This file is mirrored into `zen-term`, `zen-term-website`, and
`zen-term-releases`. Edit it here and copy it out. Anything else drifts.

---

## What ZenTerm is

**A terminal for the modern era.**

The longer version, when a sentence isn't enough:

> ZenTerm is a modern shell for a great terminal. Ghostty renders the text and
> runs the shell. ZenTerm is the app around it: floating panes, drawers, projects
> one keystroke away, and a keyboard-first way through all of it.

The purpose is polish, delight, and functionality for terminal devs of all kinds.

## Who it's for

Terminal devs of all kinds. The product leans toward people who live in the
terminal and people running agents there, but the lean is a lean. It is not the
identity, and it is not the audience.

**Do not write copy that:**

- makes agentic coding the premise ("the terminal for the agentic era")
- addresses the reader as a newcomer that AI dragged into a terminal
- treats terminal-first developers as a niche inside an AI story

Agents are one thing people run. They get their share of the copy, not the frame.

## What we don't claim

Ghostty is named. ZenTerm is a shell around it, and saying so is the positioning,
not a disclosure. Describe the relationship plainly and don't overclaim what
ZenTerm renders itself.

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
   "Fifteen built-in themes" does work that "beautifully themed" does not.
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
   character should keep returning nothing.
2. **No hype words.** seamless, powerful, beautiful, blazing, effortless,
   delightful, magical, just works, game-changer, unleash, supercharge. The
   product demonstrates these or it doesn't have them.
3. **No adverbs.** really, just, simply, actually, literally, genuinely, truly.
   They add emphasis and no meaning.
4. **Active voice, and name the actor.** "Collisions are reported" hides who.
   "The app tells you" doesn't. Inanimate things don't act: a complaint doesn't
   become a fix, a decision doesn't emerge.
5. **No "not X, it's Y" contrasts.** State Y.
6. **No fragments for drama.** "One window, one pane, your shell. That's it."
   Write complete sentences and trust them.
7. **No rhetorical questions**, no "Here's the thing," no "Let that sink in."
8. **No lazy extremes.** every, always, never, nobody. Use the specific number.
9. **Vary sentence length.** Plain does not mean staccato.
10. **Second person.** "You" beats "users" and "people."

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
> "Exit zoom (⌘F) to split."

**Errors name the place and the fix.**

> "This needs a Git repository. Run `git init` here, or open a folder that has one."
> "The bottom drawer failed to launch. Open it again to retry."
> "Failed to write open-gitdash to the config file: …"

Never leave the reader with advice they can't follow.

**Empty states: state, imperative, payoff.**

> "No tool floats yet. Add one to get a dock button and a shortcut."
> "No workspaces yet. Add one to launch a folder with its own layout from ⌘⇧P."

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
  (`"Zoom mode"` is the lone outlier and should be "Zoom Mode".)
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

| Concept | Use | Not |
|---|---|---|
| The product | **ZenTerm** | zen-term (that's the repo, the binary, and the config dir) |
| A tiled terminal region | **pane** | split (only ever a verb: "Split Horizontally") |
| A saved folder + layout | **workspace** | project, repo |
| A key combination | **shortcut** in UI, **chord** when precision matters | keybind (that's the config key name) |
| A floating tool | **tool float** first, **float** after | tool |
| Version control | **Git repository**, or **Git repo** | repo, git repository (lowercase) |

Apostrophes: straight (`'`), matching the bulk of the codebase. Two form overlays
use curly (`’`) and should be reconciled.

### The seam: UI vocabulary vs config vocabulary

The product has two vocabularies. The UI says "Workspaces" and "shortcut". The
config file says `toggle_repo_picker` and `keybind = `. `ConfigDiagnostic`
deliberately speaks the config file's vocabulary, because it names the token you
grep for, and that reasoning is sound.

**The rule:** the config vocabulary wins only where the user is looking at the
config, and the token must be a word the product still uses. `toggle_repo_picker`
fails that test. A user can be shown "⌘⇧P went to toggle_repo_picker in your
config" while every other surface says "Workspaces".

Renaming a config token is a breaking change for anyone who has bound it, so it
needs a real deprecation, not a find-and-replace.

---

## Checklist

Before any copy ships:

- [ ] Any em-dash? Remove it.
- [ ] Any hype word or adverb? Cut it.
- [ ] Passive voice, or an object doing a human verb? Name the actor.
- [ ] "Not X, it's Y"? State Y.
- [ ] Fragments stacked for drama? Write sentences.
- [ ] Does it fit its container, measured in the real font?
- [ ] One word per concept, matching the table above?
- [ ] Does every error name the fix?
- [ ] Strip the adjectives. Is the claim still true and still worth making?
