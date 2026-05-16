# Apple SDK Validation Workflows

Tarmac advertises Apple build labels from each organization's runner image
profile. Use these labels in GitHub Actions `runs-on` arrays so jobs only land
on guests that have the matching SDK and simulator runtime recorded.

These examples are unsigned PR-style checks. They verify that the project
compiles for the target Apple platform, but they do not archive, export, notarize,
or require signing credentials.

## Native iOS

Use the `ios` label for Swift, Objective-C, and mixed native iOS projects.

```yaml
name: Native iOS

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64, ios]
    steps:
      - uses: actions/checkout@v4
      - name: Build unsigned iOS app
        run: |
          xcodebuild build \
            -workspace App.xcworkspace \
            -scheme App \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## watchOS

Use the `watchos` label when the runner profile records a watchOS SDK and an
available watchOS simulator runtime.

```yaml
name: watchOS

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64, watchos]
    steps:
      - uses: actions/checkout@v4
      - name: Build unsigned watchOS app
        run: |
          xcodebuild build \
            -workspace App.xcworkspace \
            -scheme WatchApp \
            -sdk watchsimulator \
            -destination 'generic/platform=watchOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## tvOS

Use the `tvos` label when the runner profile records a tvOS SDK and an available
tvOS simulator runtime.

```yaml
name: tvOS

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64, tvos]
    steps:
      - uses: actions/checkout@v4
      - name: Build unsigned tvOS app
        run: |
          xcodebuild build \
            -workspace App.xcworkspace \
            -scheme TVApp \
            -sdk appletvsimulator \
            -destination 'generic/platform=tvOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## visionOS

Use the `visionos` label when the runner profile records a visionOS SDK and an
available visionOS simulator runtime.

```yaml
name: visionOS

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64, visionos]
    steps:
      - uses: actions/checkout@v4
      - name: Build unsigned visionOS app
        run: |
          xcodebuild build \
            -workspace App.xcworkspace \
            -scheme VisionApp \
            -sdk xrsimulator \
            -destination 'generic/platform=visionOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## Swift Package Manager

Use the `spm` label for package checks. For packages with platform-specific
targets, add the matching platform label too, then build the Xcode-generated
scheme with the same simulator SDK and destination shown above.

```yaml
name: Swift Package

on:
  pull_request:

jobs:
  test:
    runs-on: [self-hosted, macOS, ARM64, spm]
    steps:
      - uses: actions/checkout@v4
      - name: Test package on macOS
        run: swift test

  ios-build:
    runs-on: [self-hosted, macOS, ARM64, spm, ios]
    steps:
      - uses: actions/checkout@v4
      - name: Build iOS package target
        run: |
          xcodebuild build \
            -scheme PackageName \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## React Native iOS

Use the `react-native-ios` label when the runner profile records Node, at least
one JavaScript package manager, Ruby, CocoaPods, Xcode, an iOS SDK, and an
available iOS simulator runtime.

```yaml
name: React Native iOS

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64, react-native-ios]
    steps:
      - uses: actions/checkout@v4
      - name: Install JavaScript dependencies
        run: npm ci
      - name: Install pods
        run: |
          cd ios
          bundle exec pod install
      - name: Build unsigned iOS simulator app
        run: |
          xcodebuild build \
            -workspace ios/App.xcworkspace \
            -scheme App \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

## Readiness Failures

Tarmac blocks a platform label until the profile has the matching SDK and an
available simulator runtime. Fill the profile inventory from inside the guest:

```sh
xcodebuild -showsdks
xcrun simctl list runtimes
```

If a setup check reports a missing SDK or runtime, fix the base image first and
then update the profile. Do not add signing material for these validation jobs;
archive, export, notarization, and signed installable builds should use a
separate workflow that explicitly injects signing credentials.

For React Native-specific cache and signing guidance, see
[React Native iOS Runner Profile](react-native-ios-runner-profile.md).
