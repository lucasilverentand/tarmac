# Guest Bootstrap

Tarmac uses a guest LaunchDaemon installed into the base image after macOS is installed. The daemon is not loaded during preparation; it starts on later job boots through `RunAtLoad`.

Install the bootstrap from inside the base image once:

```sh
sudo /path/to/GuestBootstrap/install-tarmac-runner-bootstrap.sh
```

The installer copies:

- `/usr/local/libexec/tarmac-runner-bootstrap`
- `/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist`

At job boot the daemon mounts VirtioFS tag `shared` at `/Volumes/tarmac-shared`, tries optional tag `actions-cache` at `/Volumes/actions-cache`, validates `/Volumes/tarmac-shared/runner/run.sh` and `/Volumes/tarmac-shared/jitconfig`, then starts:

```sh
./run.sh --jitconfig /Volumes/tarmac-shared/jitconfig
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
