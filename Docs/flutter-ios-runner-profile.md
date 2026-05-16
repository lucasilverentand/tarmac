# Flutter iOS Runner Profile

The `flutter-ios` label is for Flutter apps that build iOS targets inside a
clean macOS guest. Tarmac should only advertise it when the runner image profile
has:

- Xcode selected with the license accepted
- command-line tools installed
- an iOS SDK recorded from `xcodebuild -showsdks`
- an available iOS simulator runtime recorded from `xcrun simctl list runtimes`
- Flutter, Dart, and CocoaPods versions recorded in the toolchain inventory

## Cache Contract

The guest bootstrap writes cache environment variables into `cache-env` before
starting the runner:

- `PUB_CACHE` and `TARMAC_FLUTTER_PUB_CACHE_PATH` point at
  `/Volumes/actions-cache/pub-cache`
- `TARMAC_COCOAPODS_CACHE_PATH` points at `/Volumes/actions-cache/cocoapods`
- `TARMAC_XCODE_DERIVED_DATA_PATH` points at
  `/Volumes/actions-cache/xcode-derived-data`

The bootstrap also links root's `.pub-cache`, `.cocoapods`, and Xcode
DerivedData paths to those cache directories when the Actions cache mount is
available. Do not cache the Flutter project checkout, `build/`, generated
`ios/Flutter/` intermediates, archive outputs, provisioning profiles, or
certificate material.

## Unsigned Smoke Workflow

Use unsigned simulator builds for pull requests and base image smoke checks.

```yaml
name: Flutter iOS

on:
  pull_request:

jobs:
  ios:
    runs-on: [self-hosted, macOS, ARM64, flutter-ios]
    steps:
      - uses: actions/checkout@v4
      - name: Check toolchain
        run: flutter doctor -v
      - name: Resolve packages
        run: flutter pub get
      - name: Build iOS simulator app
        run: flutter build ios --simulator --debug --no-codesign
```

This validates Flutter, Dart, CocoaPods, Xcode, and the iOS simulator SDK
without requiring Apple signing credentials.

## Signed Builds

Signed Flutter archives should use job-scoped signing credentials, not base image
state. The runner image may contain Xcode, Flutter, CocoaPods, and simulator
runtimes, but certificates and provisioning profiles must arrive through
Tarmac's temporary Apple signing payload for that job and be cleaned up by the
guest bootstrap.

Use signed archive/export workflows only on trusted branches or release jobs.
Keep Flutter dependency caches separate from signing payloads, and publish
installable outputs through GitHub Actions artifacts instead of Tarmac
diagnostics.
