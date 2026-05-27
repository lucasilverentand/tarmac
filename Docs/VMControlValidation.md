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

## Local REST Control

Tarmac can expose a loopback-only REST API for VM lifecycle control. It is disabled by default.

1. Open **Dashboard → Cache & Diagnostics** and enable **Local VM Control API**.
2. Copy the generated bearer token from settings.
3. With the app running and a verified base image, call the endpoints:

```sh
export TARMAC_VM_CONTROL_TOKEN='<token from settings>'
script/vm_control_smoke.sh
```

Endpoints:

- `GET /health` — service liveness
- `GET /vm` — structured `VMInstance` state
- `POST /vm/boot` — clone base image and boot (requires bearer token)
- `POST /vm/stop` — stop the running VM (requires bearer token)
- `POST /vm/teardown` — stop, delete clone, and clear control scratch (requires bearer token)

The listener binds to `127.0.0.1` only (`acceptLocalOnly` plus loopback endpoint checks).
Lifecycle-changing requests require `Authorization: Bearer <token>`.
The app tears down any owned VM and stops the listener on quit.
