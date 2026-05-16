# macOS Packaging and Notarization

Tarmac advertises the `macos-distribution` runner label only when the selected runner image profile has the macOS SDK, Xcode command-line tools, packaging tools, signing identity names, and notarization credentials configured. Signing certificates and App Store Connect secrets must be supplied at job time; they should not be baked into the base image.

## Runner Image Profile

Enable the macOS Distribution capability on the organization runner image profile and record:

- `notarytool`, `productbuild`, `pkgbuild`, `hdiutil`, and `stapler` availability
- the Developer ID Application identity name used for `.app` signing
- the Developer ID Installer identity name used for `.pkg` signing
- the notarization credential source, either per-job environment secrets or App Store Connect API key secrets
- the confirmation that notarization credentials are supplied outside the base image

The profile also needs a macOS SDK entry, Xcode version, selected developer directory, and command-line tools. If any required input is missing, Tarmac withholds the `macos-distribution` label and surfaces the first readiness issue in Settings, setup checks, and startup readiness.

## Workflow Shape

This is the expected shape for a signed Developer ID release workflow:

```yaml
name: macOS Release

on:
  workflow_dispatch:

jobs:
  release:
    runs-on:
      - self-hosted
      - macOS
      - ARM64
      - macos-distribution

    env:
      APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
      APPLE_ID: ${{ secrets.APPLE_ID }}
      NOTARYTOOL_PASSWORD: ${{ secrets.NOTARYTOOL_PASSWORD }}

    steps:
      - uses: actions/checkout@v4

      - name: Build archive
        run: |
          xcodebuild archive \
            -scheme Example \
            -archivePath "$RUNNER_TEMP/Example.xcarchive"

      - name: Export app
        run: |
          xcodebuild -exportArchive \
            -archivePath "$RUNNER_TEMP/Example.xcarchive" \
            -exportPath "$RUNNER_TEMP/export" \
            -exportOptionsPlist ExportOptions.plist

      - name: Package app
        run: |
          mkdir -p "$RUNNER_TEMP/notary"
          ditto -c -k --keepParent \
            "$RUNNER_TEMP/export/Example.app" \
            "$RUNNER_TEMP/notary/Example.zip"

      - name: Notarize
        run: |
          mkdir -p "$TARMAC_SHARED_DIRECTORY/apple-distribution-diagnostics"
          xcrun notarytool submit "$RUNNER_TEMP/notary/Example.zip" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$NOTARYTOOL_PASSWORD" \
            --wait \
            --output-format json \
            | tee "$TARMAC_SHARED_DIRECTORY/apple-distribution-diagnostics/notarytool.json"

      - name: Staple
        run: |
          xcrun stapler staple "$RUNNER_TEMP/export/Example.app" \
            2>&1 | tee "$TARMAC_SHARED_DIRECTORY/apple-distribution-diagnostics/stapler.log"

      - uses: actions/upload-artifact@v4
        with:
          name: Example.app
          path: ${{ runner.temp }}/export/Example.app
```

For `.pkg` releases, build the package with `pkgbuild` or `productbuild`, then submit the package to `notarytool` and staple the accepted package before upload.

## Diagnostics

Workflows can write notarization and packaging logs to:

```text
$TARMAC_SHARED_DIRECTORY/apple-distribution-diagnostics
```

Tarmac preserves that directory in the retained job diagnostics bundle. Text diagnostics are copied with common Apple credential fields redacted. Signing material such as `.p12`, `.pem`, `.p8`, provisioning profiles, keychains, and certificates is omitted from diagnostics.

Useful files to keep there:

- `notarytool.json`
- `notarytool.log`
- `stapler.log`
- `productbuild.log`
- `pkgbuild.log`
- `hdiutil.log`

Do not write raw certificates, provisioning profiles, keychains, or exported API keys into this directory. Use GitHub Actions artifacts for release outputs such as `.app`, `.pkg`, `.dmg`, `.xcarchive`, or `.dSYM`; diagnostics are for logs and failure context.
