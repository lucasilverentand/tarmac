# Expo/EAS iOS Runner Profile

The `expo-ios` label is for Expo apps that run EAS local iOS builds inside a
clean macOS guest. It builds on the React Native iOS profile. Tarmac should only
advertise it when the runner image profile has:

- Xcode selected with the license accepted
- command-line tools installed
- an iOS SDK recorded from `xcodebuild -showsdks`
- an available iOS simulator runtime recorded from `xcrun simctl list runtimes`
- Node.js and at least one package manager recorded in the toolchain inventory
- Ruby and CocoaPods recorded in the toolchain inventory
- Expo CLI and EAS CLI recorded in the toolchain inventory

## Cache Contract

Expo and EAS local builds use the same safe cache boundary as React Native:

- package manager caches live under `/Volumes/actions-cache`
- CocoaPods cache lives under `/Volumes/actions-cache/cocoapods`
- Xcode DerivedData lives under `/Volumes/actions-cache/xcode-derived-data`

Do not persist Expo auth state, EAS local build working directories, generated
native projects, `ios/Pods`, archives, provisioning profiles, certificates,
keychains, or submission payloads. Those are job state, not base image state.

## Unsigned Smoke Workflow

Use a simulator EAS profile for pull requests and base image smoke checks. The
profile should not need Apple signing credentials.

```json
{
  "build": {
    "simulator": {
      "ios": {
        "simulator": true
      }
    }
  }
}
```

```yaml
name: Expo EAS iOS

on:
  pull_request:

jobs:
  ios:
    runs-on: [self-hosted, macOS, ARM64, expo-ios]
    env:
      EXPO_NO_TELEMETRY: "1"
      EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - name: Install JavaScript dependencies
        run: npm ci
      - name: Verify Expo project
        run: npx expo-doctor
      - name: Run local simulator build
        run: eas build --platform ios --local --profile simulator --non-interactive
```

This validates Node, the selected package manager, Expo CLI, EAS CLI, Ruby,
CocoaPods, Xcode, and the iOS simulator SDK without requiring Apple signing
credentials.

## Credentials

Use `EXPO_TOKEN` as a GitHub Actions secret for non-interactive EAS commands.
Do not run `eas login` during base image preparation, and do not store Expo auth
files in the base image.

Signed EAS local builds should use Tarmac's job-scoped Apple signing payload,
not certificates or provisioning profiles installed into the base image. Keep
those workflows on trusted branches or release jobs.

## Out Of Scope

Tarmac's `expo-ios` label is for self-hosted EAS local iOS builds. EAS cloud
builders, EAS cloud credentials sync, App Store submission, and hosted EAS
Workflows are separate services. Jobs that require those cloud-only paths should
run against Expo's service directly or use a separate workflow that makes the
cloud dependency explicit.
