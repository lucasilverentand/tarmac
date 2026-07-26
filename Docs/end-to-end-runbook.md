# End-to-End Runbook

How to take Tarmac from a clean checkout to a real GitHub Actions job running
inside a fresh macOS 27 VM and torn down afterwards. Base-image owner creation,
automatic login, and bootstrap installation are unattended.
Each step links to the deeper reference doc where one exists.

The host code path is complete — there are no stubs in auth, polling, dispatch,
VM boot, teardown, or cache. What stands between a clean checkout and a green
job is configuration and the base image. Most failures below surface only when
the first VM boots and the host waits out the runner-completion timeout (default
1 hour), so verify each prerequisite before queuing a job.

## 1. Host machine

- Apple Silicon Mac running macOS 27.
- Tarmac built and signed with the Virtualization entitlements
  (`com.apple.security.virtualization`, `com.apple.security.network.client`).
  Building and running the signed app from Xcode is enough; no extra user step.
- Storage root on a fast APFS volume. An external Thunderbolt/USB4 NVMe SSD is
  fine as long as it is APFS and not inside a cloud-synced folder. Settings →
  Storage flags a non-APFS or cloud-synced path before you start.

## 2. Base image (once per macOS version)

See [base-image-preparation.md](base-image-preparation.md) for the full steps.

1. Create the base image from an IPSW (`VMEngine.createBaseImage`) or point
   Tarmac at a pre-built `BaseImage.img`.
   - If you supply a pre-built image, the platform data files
     (`Platform/hardwareModel.bin`, `machineIdentifier.bin`,
     `auxiliaryStorage.bin`) must exist alongside it. They are generated during
     `createBaseImage`; a VM boot fails immediately without them.
2. The wizard starts macOS 27 with Apple's guest-provisioning protocol, creates
   the `tarmac` volume owner with a Keychain-protected generated password,
   enables automatic login, and installs the guest bootstrap over its private
   SSH provisioning channel. Setup Assistant is not shown. Then install the build toolchain:
   Xcode,
   `xcodebuild -license accept`, `xcode-select --switch`, plus any profile tools
   (Flutter, Node, Ruby/CocoaPods, Expo/EAS) per the runner image profile.
3. Verify the image (`VMEngine.verifyBaseImage`) so it gets a verified marker.

## 3. Guest bootstrap (once per base image)

See [guest-bootstrap.md](guest-bootstrap.md). The base-image wizard installs
the three bundled resources automatically after macOS 27 provisions the
`tarmac` owner. The LaunchDaemon disables screen lock and guest sleep. This
installs
`/usr/local/libexec/tarmac-runner-bootstrap` and the
`studio.seventwo.tarmac.runner-bootstrap` LaunchDaemon. On every job boot the
daemon mounts the VirtioFS `shared` tag, optionally mounts `actions-cache`,
runs `./run.sh --jitconfig` only after `tarmac` is the console user, writes
`bootstrap.log` / `runner.log` /
`exit-code` / `completion.json` back to the shared job directory, and shuts the
guest down.

Verification fails closed if this is not installed, preventing a guest that
cannot mount its shared directory or start the runner from entering the queue.

## 4. GitHub account (per org or enterprise)

See [github-runner-api-strategy.md](github-runner-api-strategy.md) for
permissions and the support matrix.

**Organization (GitHub App):**

1. Create a GitHub App on the org with self-hosted runner write permission.
2. Download its private key and import it in Tarmac → Accounts (stored in the
   Keychain). Both PKCS#1 and PKCS#8 PEMs are accepted.
3. Set the org name, App ID, and installation ID (discoverable automatically).

**Enterprise (access token):**

1. Create an enterprise access token with `manage_runners:enterprise` (not a
   fine-grained PAT, not a GitHub App installation token).
2. Import it in Tarmac → Accounts with account type **Enterprise**.

**Both:**

3. In Tarmac → Accounts → Runner, use **Create / Find Scale Set**. Tarmac
   lists existing runner scale sets for the account, reuses the default
   `tarmac-macos` set when present, or creates it through the Actions-service
   scale-set API. The returned numeric **scale set ID** is written back to the
   account config. Polling will not start without that ID.
4. Set the runner **labels** (default `self-hosted, macOS, ARM64`) to match the
   workflow `runs-on` contract. The runner group is taken automatically from the
   scale set when the polling session is created — no manual group ID needed
   (see [github-runner-api-strategy.md](github-runner-api-strategy.md), "Runner
   groups and routing").
5. Make sure the org is enabled.

The app runs setup checks on start (App ID, private key, scale set ID, runner
group, labels) and surfaces failures in the Accounts UI immediately.

## 5. Run the first job

1. Add a minimal workflow to a repo the scale set can serve:

   ```yaml
   name: tarmac-e2e
   on: workflow_dispatch
   jobs:
     smoke:
       runs-on: [self-hosted, macOS, ARM64]
       steps:
         - run: sw_vers && xcodebuild -version
   ```

2. Start Tarmac and confirm the org's polling session is active (Dashboard).
3. Dispatch the workflow. Expected path: `JobAvailable` → enqueue →
   clone base disk → boot VM → guest runs `run.sh --jitconfig` → `JobCompleted`
   → stop VM → delete clone and per-job directory → mark completed.
4. Confirm the cloned disk under `disks/` and the per-job directory under
   `jobs/<jobId>/` are gone after teardown.

## 6. Exercise the acceptance criteria

- **Failure path:** push a workflow step that exits non-zero. The VM still tears
  down and the clone is deleted, and a diagnostics bundle is preserved (boot log,
  runner log, exit code). Confirm the bundle exists under `diagnostics/`.
- **Clean clone + cache reuse:** run a second job. It must boot from a fresh
  clone of the base image (no state from job 1) while the configured cache at
  `/Volumes/actions-cache` still carries entries from job 1. Enable the cache in
  Settings → Cache first.

## Known rough edges (follow-up, not blockers)

- If the app crashes mid-teardown, the cloned disk and job directory can linger
  until the 24h transient-file cleanup runs.
- The downloaded runner tarball checksum (`RunnerDownloadInfo.sha256Checksum`)
  is not validated.

These are tracked separately; none prevent a successful end-to-end run.
