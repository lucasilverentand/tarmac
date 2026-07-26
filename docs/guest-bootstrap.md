# Guest Bootstrap

Tarmac uses a guest LaunchDaemon installed automatically after macOS 27 creates
the `tarmac` owner. The daemon is not loaded during preparation; it starts on
later verification and job boots through `RunAtLoad`.

For manual repair of an already-owned image, run:

```sh
sudo /path/to/GuestBootstrap/install-tarmac-runner-bootstrap.sh
```

The macOS 27 provisioning path generates the dedicated account password, stores
it in the host Keychain, asks macOS to enable automatic login, and enables
Remote Login on the VM's private NAT network for provisioning and maintenance.
Tarmac then runs this installer with `--skip-auto-login`
over the private NAT provisioning channel because Apple has already configured
the login policy. On later boots the daemon disables screen locking and guest
sleep and verifies that `tarmac` owns the interactive console.

Automatic login means anyone with access to Tarmac's VM display can access the
guest desktop. Keep production credentials out of the base image; inject them
only into the ephemeral job clone.

`script/install_guest_bootstrap_offline.sh` supports prepared images that
already contain a macOS-created local owner. It refuses ownerless images and
never writes `.AppleSetupDone`; bypassing owner provisioning would leave the
virtual Mac without a volume owner and can send it into Recovery. The
injector adds a root-only, randomly generated runner password seed alongside
the daemon. Each ephemeral clone uses that seed to configure automatic login and restart
`loginwindow`; the daemon deletes the seed from the clone before the desktop or
Actions runner starts. Set
`TARMAC_RUNNER_PASSWORD` before running the injector only when you need a known
guest password. Because the seed remains in the host-owned base image, protect
the Tarmac storage root like any other credential-bearing build asset.

The installer copies:

- `/usr/local/libexec/tarmac-runner-bootstrap`
- `/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist`

At job boot the daemon mounts VirtioFS tag `shared` at `/Volumes/tarmac-shared`, tries optional tag `actions-cache` at `/Volumes/actions-cache`, waits until `tarmac` owns `/dev/console`, writes `interactive-session-ready`, validates `/Volumes/tarmac-shared/runner/run.sh`, then starts the runner using either:

**JIT config (default):**

```sh
./run.sh --jitconfig /Volumes/tarmac-shared/jitconfig
```

**Registration token fallback** when JIT config is unavailable and the host writes:

- `/Volumes/tarmac-shared/registration-token`
- `/Volumes/tarmac-shared/runner-url`
- `/Volumes/tarmac-shared/runner-name`
- `/Volumes/tarmac-shared/runner-labels` (comma-separated)

```sh
./config.sh --url <runner-url> --token <registration-token> --name <runner-name> --labels <runner-labels> --unattended --replace
./run.sh
```

When the cache mount is present, the bootstrap creates first-version cache targets under `/Volumes/actions-cache`:

- `swiftpm`
- `xcode-derived-data`
- `cocoapods`
- `pub-cache`
- `npm`
- `yarn`
- `pnpm-store`
- `bun-install-cache`

The bootstrap links the root user cache locations in the cloned guest disk to those persistent directories, writes `/Volumes/tarmac-shared/cache-env`, and sources that file before starting the runner. The exported variables are:

- `TARMAC_ACTIONS_CACHE`
- `TARMAC_SWIFTPM_CACHE_PATH`
- `TARMAC_XCODE_DERIVED_DATA_PATH`
- `TARMAC_COCOAPODS_CACHE_PATH`
- `TARMAC_FLUTTER_PUB_CACHE_PATH`
- `PUB_CACHE`
- `TARMAC_NPM_CACHE_PATH`
- `NPM_CONFIG_CACHE`
- `TARMAC_YARN_CACHE_PATH`
- `YARN_CACHE_FOLDER`
- `TARMAC_PNPM_STORE_PATH`
- `PNPM_STORE_PATH`
- `TARMAC_BUN_INSTALL_CACHE_PATH`
- `BUN_INSTALL_CACHE_DIR`

The guest writes `bootstrap.log`, `runner.log`, `exit-code`, and cache setup details into the shared job directory before requesting shutdown.

Base image verification also boots a temporary shared-directory probe. The
probe succeeds only after the automatic desktop session is active. When the
LaunchDaemon runs the probe successfully, Tarmac writes a versioned
`Platform/guestBootstrapVerified.json` beside the base image verification marker.
Jobs are refused before VM provisioning when that marker is missing, so a base
image without the current bootstrap and login contract fails quickly instead of
waiting for the runner completion timeout. After installing or updating the
bootstrap in an existing base image, rerun base image verification so the host
marker reflects the prepared image.
