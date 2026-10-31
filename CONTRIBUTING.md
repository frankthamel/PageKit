# Contributing to PageKit

Thanks for helping. Bug reports, fixes, documentation and ideas are all welcome. By taking part, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting a bug

[Open an issue](https://github.com/frankthamel/PageKit/issues/new/choose). The template asks for your API style (index or cursor), your cache policy and a minimal reproduction, which saves a round trip.

## Proposing a change

For anything larger than a small fix, open an issue first, so we can agree on the approach before you spend time on it.

## Getting set up

PageKit itself needs Xcode 16 or later (Swift 6.0). To work on it, use Xcode 16.3 or later (Swift 6.1): the test suite's hang watchdog uses Swift Testing's `TestScoping`, so on Swift 6.0 a hung test would wait for ever. CI only runs Xcode 26.6 and 27.1, so anything older is untested. Then:

```sh
git clone https://github.com/frankthamel/PageKit.git
cd PageKit
swift test
```

Before opening a pull request, run what CI runs:

```sh
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcodebuild docbuild -scheme PageKit -destination 'generic/platform=macOS' OTHER_DOCC_FLAGS=--warnings-as-errors
```

On Xcode 26.6 and 27.1, CI also builds for iOS, tvOS and watchOS. Tests run on macOS only. CI also checks for API breaks against the last tag.

## Project rules

- **No dependencies.** PageKit imports only Foundation, Network, CryptoKit and os. It never imports SwiftUI, UIKit or AppKit.
- **Keep the deployment targets.** iOS 15, macOS 12, tvOS 15, watchOS 8. Avoid newer APIs, such as `Clock`.
- **Zero warnings** under strict concurrency.
- **Re-check after every `await`.** In `Paginator`, generation and state must be checked again before anything changes.
- **Document every public symbol** with a plain-English DocC comment.
- **Write the test first,** using Swift Testing. Tests must never touch the real cache folders.
- **Keep it simple.** One responsibility per file, and no abstraction without a second implementation or a test that needs it.

## Pull requests

- Keep each pull request to one change.
- Use a [conventional](https://www.conventionalcommits.org) subject, such as `fix: keep edits sound across duplicates`.
- Add user-facing changes to [CHANGELOG.md](CHANGELOG.md).
- If you change the public API, update the README and the DocC articles.

PageKit follows semantic versioning: a patch is a bug fix, a minor version is a new feature, and a major version is a breaking change.

## Licence

By contributing, you agree that your work is licensed under the [MIT licence](LICENSE).
