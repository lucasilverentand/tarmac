# Apple signing credentials

Tarmac treats Apple signing credentials as job-scoped inputs, not base image state.

## Host storage

Signing asset metadata is stored in configuration:

- display name
- Apple team ID
- bundle identifier pattern
- certificate common name
- provisioning profile UUID
- certificate and profile expiration dates

Sensitive material is stored separately in the host keychain under `apple-signing-*` keys:

- `.p12` certificate data
- `.p12` passphrase
- provisioning profile data

These keys are intentionally separate from GitHub App private key entries, which use the `github-app-private-key-*` prefix.

## Guest injection

When a job needs signing, the host writes an `apple-signing/` directory into that job's shared VirtioFS directory:

- `certificate.p12`
- `profile.mobileprovision`
- `signing-env`
- `import-signing-assets.sh`

The guest bootstrap sources `import-signing-assets.sh` before starting the runner. The script creates a temporary keychain, imports the certificate, sets the key partition list for codesigning tools, installs the provisioning profile, and registers a cleanup trap.

The cleanup trap removes:

- the installed provisioning profile
- the temporary keychain
- the shared `apple-signing/` payload

Diagnostics retention only copies the known lifecycle and runner log files. It does not retain the `apple-signing/` directory.

## Validation

A signing asset is not ready when:

- required metadata is missing
- certificate, passphrase, or provisioning profile data is absent from the keychain
- the certificate or provisioning profile is expired
- the requested bundle identifier does not match the asset pattern

Bundle identifier patterns support exact matches, `*`, and prefix patterns such as `com.example.*`.
