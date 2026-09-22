# Contributing

Bug reports and ideas are welcome: open an issue.

## Pull requests

Joseon is also distributed through the Mac App Store. The App Store terms and the GPL do not
fit together for code that other people own. For this reason the maintainer must hold the
copyright to all code in this repository.

- Small fixes (typos, a one-line bug fix): open a PR and state in it that you give the
  maintainer the right to relicense your change.
- Larger changes: open an issue first. The maintainer will ask you to sign a Contributor
  License Agreement (CLA) before the PR can merge.

## Build and test

```bash
swift build && swift test
```

The timing tests (engine tick, render cost, `process` budget) only run in release mode. Run
them before a merge:

```bash
swift build -c release --build-tests -Xswiftc -enable-testing && swift test -c release --skip-build -Xswiftc -enable-testing
```

Rules for changes:

- Modules talk only through `Sources/JoseonCore/Contracts.swift` and `Sources/JoseonRender/RenderContracts.swift`.
- No allocation and no locks on the audio and analysis threads.
- Tests must never play audio and must never open an audio input.
