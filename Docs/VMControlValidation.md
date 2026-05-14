# VM Control Validation

Validated on May 14, 2026 with the local Virtualization.framework smoke runner.

## Command

```sh
script/vm_smoke.sh --boot-hold-seconds 5
```

## Result

- The smoke binary built and was signed with the app entitlements.
- The runner found the local Tarmac storage root and base image.
- A cloned VM disk was created for the run.
- The VM started successfully from the clone.
- The VM accepted the stop request and shut down cleanly.
- The cloned disk was removed after the run.

The relevant smoke output was:

```text
Starting VM from clone smoke-180AE12E-2606-4A01-96CA-85CBC3ACC0BF.img
VM start succeeded.
VM stopped cleanly.
```

## Follow-Up

External REST control is not part of the current app surface yet. The follow-up work is tracked in
GitHub issue #13: add a local-only REST control service for VM health, state, boot, stop, and teardown calls.
