# Release management

Tarmac ships from signed `vX.Y.Z` tags. The release workflow builds the app with
Developer ID signing, notarizes it with Apple, staples the exported app, uploads
the zip and checksum as workflow artifacts, and publishes a GitHub Release for
tag-triggered runs.

## Versioning

- Use semantic versions: `MAJOR.MINOR.PATCH`.
- Use prerelease suffixes when needed, for example `1.2.0-beta.1`.
- Tags must include a leading `v`, for example `v1.2.0`.
- The app bundle version is set from the tag at archive time. The checked-in
  default remains `0.1.0` in `Project.swift`.

## Required GitHub secrets

| Secret | Purpose |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID used for Developer ID signing and notarization. |
| `APPLE_ID` | Apple ID passed to `xcrun notarytool`. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization. |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate `.p12`. |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password for the `.p12` certificate. |
| `RELEASE_KEYCHAIN_PASSWORD` | Temporary keychain password used by the workflow runner. |

## Release checklist

1. Make sure `main` is green.
2. Decide the next semver version.
3. Create and push a signed tag:

   ```sh
   git tag -s v1.2.0 -m "release: v1.2.0"
   git push origin v1.2.0
   ```

4. Watch the `Release` workflow.
5. Download the published zip and checksum from the GitHub Release.
6. Verify the checksum and Gatekeeper trust:

   ```sh
   shasum -a 256 -c Tarmac-1.2.0.zip.sha256
   unzip Tarmac-1.2.0.zip
   spctl --assess --type execute --verbose Tarmac.app
   codesign --verify --deep --strict --verbose=2 Tarmac.app
   ```

## Local release dry run

Use this to prove signing and packaging without publishing a GitHub Release:

```sh
DEVELOPMENT_TEAM=TEAMID \
APPLE_ID=name@example.com \
APPLE_APP_SPECIFIC_PASSWORD=app-specific-password \
script/release.sh --version 1.2.0
```

For signing-only validation without notarization:

```sh
DEVELOPMENT_TEAM=TEAMID script/release.sh --version 1.2.0 --skip-notarization
```
