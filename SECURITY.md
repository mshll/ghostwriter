# Security policy

Ghostwriter has Accessibility access, can read the screen and posts key events. A bug can expose what users type, so security reports get priority.

## Supported versions

Only the latest release gets security fixes. Ghostwriter updates itself, so most users run the latest release.

## Report a vulnerability

Do not open a public issue. Report it privately through [GitHub's private vulnerability reporting](https://github.com/mshll/ghostwriter/security/advisories/new).

Include:

- The version of Ghostwriter and macOS, and the chip of your Mac
- What an attacker can do, and what they need first
- Steps to reproduce, or a proof of concept

You get a reply within a week. When a fix is released, the advisory is published with credit to you, unless you prefer to stay anonymous.

## In scope

- Text that the user wrote leaves the Mac, or reaches logs or files that it should not
- Text is recorded from secure fields, password managers or excluded apps
- Another process can make Ghostwriter type, read or run something
- The update or model download accepts a file that is not the one published (signature or checksum bypass)

## Out of scope

- Attacks that need administrator access or physical access to an unlocked Mac
- Content that a model writes. Models can be wrong or offensive; report that as a normal issue.
- Bugs in llama.cpp, Sparkle or macOS. Report those to their projects.
