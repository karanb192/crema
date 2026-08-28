# Contributing

Glad you are here. Crema is a small Swift package and easy to hack on.

## Build and test

```bash
swift build      # compile
swift test       # engine test suite, must stay green
make run         # build a release .app and launch it
```

Xcode 15+ / Swift 5.9+, macOS 13+, Apple Silicon.

## Ground rules

- Engine changes (CremaCore) come with a test. The whole point of the
  split is that power decisions stay unit-testable.
- The popover is deliberately small. Features that add a second screen or a
  settings window need an issue discussion first.
- Honest copy only: the README never claims something the code does not do.
  If your PR adds a capability, update the Limits section in the same PR.
- One more agent's precise turn signal (see SessionActivityProbe) is the
  most wanted kind of PR.

Open an issue first for anything bigger than a fix, so nobody builds twice.
