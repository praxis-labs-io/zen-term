# Security

ZenTerm ships a signed, notarized macOS app that updates itself, so a bug in the
wrong place reaches machines. Report anything with a security angle privately
first.

## Reporting

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/praxis-labs-io/zen-term/security/advisories/new).
It opens a private thread visible only to the maintainers. Do not open a public
issue for a vulnerability.

Include what you would put in any bug report: the version (⌘, and read the bottom
of the left column), your macOS build, and the steps. If you have a proof of
concept, attach it.

You will get a first reply within a week. If you do not, open a public issue
saying only that you are waiting on a security report, with no details in it.

## What counts

Worth reporting:

- Anything that lets a remote party run code through terminal output: an escape
  sequence, an OSC handler, a hyperlink, a pasted payload.
- A path that writes or reads outside what the user asked for, including through
  the config file, workspace files, or a tool float's command.
- Anything that weakens the update chain: signature verification, the appcast, the
  notarized bundle.
- Credential or secret exposure, including anything a diagnostics bundle or issue
  report collects that it should not.

Not a vulnerability, and better as a normal issue:

- A crash with no path to code execution or data exposure.
- Behavior that requires the attacker to already have your config file, your
  keychain, or a shell on your machine.
- A finding against libghostty's terminal emulation itself. Report those to
  [ghostty](https://github.com/ghostty-org/ghostty/security), which is where the
  fix has to land. Tell us too if ZenTerm makes it worse or reachable in a way
  ghostty alone is not.

## Scope

The current release, and `main`. Older versions get a fix by way of the next
release rather than a backport.

## What ZenTerm sends

Nothing about you. There is no telemetry, no analytics, and no account. The update
check asks GitHub for a version number. **Help → Report an Issue** builds a
prefilled GitHub URL and a diagnostics bundle from local logs, both of which you
see and send yourself.
