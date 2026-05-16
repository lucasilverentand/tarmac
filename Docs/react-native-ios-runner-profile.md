# React Native iOS Runner Profile

The `react-native-ios` label is for React Native apps that build iOS targets
inside a clean macOS guest. Tarmac should only advertise it when the runner image
profile has:

- Xcode selected with the license accepted
- command-line tools installed
- an iOS SDK recorded from `xcodebuild -showsdks`
- an available iOS simulator runtime recorded from `xcrun simctl list runtimes`
- Node.js and at least one package manager recorded in the toolchain inventory
- Ruby and CocoaPods recorded in the toolchain inventory

## Cache Contract

The guest bootstrap writes cache environment variables into `cache-env` before
starting the runner:

- `NPM_CONFIG_CACHE` and `TARMAC_NPM_CACHE_PATH` point at
  `/Volumes/actions-cache/npm`
- `YARN_CACHE_FOLDER` and `TARMAC_YARN_CACHE_PATH` point at
  `/Volumes/actions-cache/yarn`
- `PNPM_STORE_PATH` and `TARMAC_PNPM_STORE_PATH` point at
  `/Volumes/actions-cache/pnpm-store`
- `BUN_INSTALL_CACHE_DIR` and `TARMAC_BUN_INSTALL_CACHE_PATH` point at
  `/Volumes/actions-cache/bun-install-cache`
- `TARMAC_COCOAPODS_CACHE_PATH` points at `/Volumes/actions-cache/cocoapods`
- `TARMAC_XCODE_DERIVED_DATA_PATH` points at
  `/Volumes/actions-cache/xcode-derived-data`

The bootstrap also links root's `.npm`, `.cache/yarn`, `.pnpm-store`,
`.bun/install/cache`, `.cocoapods`, and Xcode DerivedData paths to those cache
directories when the Actions cache mount is available.

Do not cache the repository checkout, `node_modules`, `ios/Pods`,
`ios/build`, Xcode archives, export outputs, provisioning profiles,
certificates, keychains, or generated files that may contain job-specific
secrets. Let package-manager install commands repopulate workspace-local folders
from the persistent package caches.

## Unsigned Smoke Workflow

Use unsigned simulator builds for pull requests and base image smoke checks.

```yaml
name: React Native iOS

on:
  pull_request:

jobs:
  ios:
    runs-on: [self-hosted, macOS, ARM64, react-native-ios]
    steps:
      - uses: actions/checkout@v4
      - name: Install JavaScript dependencies
        run: npm ci
      - name: Install pods
        run: |
          cd ios
          bundle exec pod install
      - name: Build iOS simulator app
        run: |
          xcodebuild build \
            -workspace ios/App.xcworkspace \
            -scheme App \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO
```

This validates Node, the selected package manager, Ruby, CocoaPods, Xcode, and
the iOS simulator SDK without requiring Apple signing credentials.

## Signed Builds

Signed React Native archives should use job-scoped signing credentials, not base
image state. The runner image may contain Xcode, Node, package managers, Ruby,
CocoaPods, and simulator runtimes, but certificates and provisioning profiles
must arrive through Tarmac's temporary Apple signing payload for that job and be
cleaned up by the guest bootstrap.

Use signed archive/export workflows only on trusted branches or release jobs.
Keep JavaScript and CocoaPods caches separate from signing payloads, and publish
installable outputs through GitHub Actions artifacts instead of Tarmac
diagnostics.
