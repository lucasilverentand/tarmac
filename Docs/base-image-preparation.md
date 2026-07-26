# Base Image Preparation

Tarmac treats the macOS base image and the runner image profile as one contract:
the base image contains the tools, and the profile records what the image can
advertise to GitHub.

## Unattended macOS 27 Setup

Tarmac requires a macOS 27 restore image so the base image can be provisioned
without Setup Assistant:

1. Install the macOS 27 restore image from the base-image wizard.
2. Tarmac starts the image once with `VZMacGuestProvisioningOptions`, creates
   the `tarmac` volume owner, stores its generated password in Keychain, enables
   automatic login, and enables Remote Login on the VM's private NAT network
   for bootstrap installation and maintenance.
3. Tarmac resolves the guest's private NAT lease and installs the bundled guest
   bootstrap over that provisioning channel. No password or Setup Assistant
   interaction is required.
4. The wizard stops the real base image, boots a clone, and verifies the
   LaunchDaemon, automatic desktop login, and shared-directory handshake.

After provisioning, prepare the build capabilities included in the image:

1. Install Xcode into `/Applications`.
2. Accept the Xcode license.
3. Select the developer directory with `xcode-select`.
4. Install or verify command-line tools.
5. Install simulator runtimes for every advertised platform.
6. Install optional toolchains such as Flutter, Node, Ruby, CocoaPods, Expo CLI,
   and EAS CLI when a profile needs them.
7. Scan and record the finished image profile before advertising its labels.

Use the VM display's **Take Over** mode when inspecting or maintaining the
image. Tarmac attaches a virtual USB keyboard and absolute-coordinate pointing
device to both the installer and every normal VM boot, so login windows and the
guest desktop accept host keyboard and pointer input. Switch back to **Observe**
to release system-key capture.

The host-side `script/install_guest_bootstrap_offline.sh` remains a repair tool
for already-owned images. It refuses ownerless images and never writes
`.AppleSetupDone`; owner creation belongs to Apple's macOS 27 provisioning
protocol.

Use **Scan Image** in the account's runner image profile to automate this
inventory. Tarmac boots a temporary clone of the selected runner image, runs the
toolchain checks inside the guest, records the discovered SDKs, runtimes, and
tool versions, then advertises only the labels that pass readiness checks.

Runner image profiles can point at a specific disk image path and can override
CPU, memory, disk size, and runner timeout for jobs that use that profile. Leave
the image path empty to use the managed `BaseImage.img`; set it when an account
or runner class needs a separate Xcode or platform image.

A profile should only advertise labels once its required SDKs, simulator
runtimes, license state, and optional tools are present. The scan action is the
preferred way to keep that contract current.

## Toolchain Checks

Use these commands inside the guest to fill the inventory:

```sh
xcode-select --print-path
xcodebuild -version
xcodebuild -license check
xcodebuild -showsdks
xcrun simctl list runtimes
pkgutil --pkg-info=com.apple.pkg.CLTools_Executables
flutter --version
dart --version
node --version
npm --version
yarn --version
pnpm --version
bun --version
ruby --version
pod --version
npx expo --version
eas --version
```

Flutter iOS profiles need Flutter, Dart, CocoaPods, Xcode, and the iOS SDK.
React Native iOS profiles need Node, at least one JavaScript package manager,
CocoaPods, Ruby, Xcode, and the iOS SDK. Expo iOS profiles additionally need
Expo CLI and EAS CLI.

For unsigned native iOS, watchOS, tvOS, visionOS, and Swift Package Manager
workflow examples, see [Apple SDK Validation Workflows](apple-sdk-validation-workflows.md).
For Flutter-specific readiness and cache behavior, see
[Flutter iOS Runner Profile](flutter-ios-runner-profile.md).
For React Native-specific readiness and cache behavior, see
[React Native iOS Runner Profile](react-native-ios-runner-profile.md).
For Expo/EAS-specific readiness and local build behavior, see
[Expo/EAS iOS Runner Profile](expo-eas-ios-runner-profile.md).
