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

The guest writes `bootstrap.log`, `runner.log`, and `exit-code` into the shared job directory before requesting shutdown.
