# Tarmac

Native macOS app that runs ephemeral GitHub Actions runners inside virtual macOS machines on Apple Silicon.

## Build

```sh
tuist generate
xcodebuild build -scheme Tarmac -destination 'platform=macOS'
```

## Test

```sh
xcodebuild test -scheme Tarmac -destination 'platform=macOS'
```

## Architecture

```
TarmacApp (@main)
├── MenuBarExtra (status icon + popover summary)
├── Window "Dashboard" (visual job queue + VM status)
└── Settings (orgs, credentials, VM config)
```

**Engines** (actors) handle all async work:
- `GitHubEngine` — GitHub App auth (RS256 JWT → installation tokens), runner binary management
- `QueueEngine` — Scale Set long-polling, job queue (FIFO), sequential dispatch
- `VMEngine` — Virtualization.framework VM lifecycle (clone → boot → run → teardown)

**ViewModels** (`@Observable @MainActor`) bridge engines to SwiftUI views.

**Services** provide persistence:
- `ConfigStore` — UserDefaults for orgs, VM config
- `KeychainService` — SecItem* for GitHub App private key
- `PlatformDataStore` — hardwareModel/machineIdentifier for VZ*

## Conventions

- **Actors** for all engine types (thread-safe by default)
- **@Observable @MainActor** for ViewModels
- **Protocol-based DI** — every engine has a protocol for testability (e.g., `GitHubClientProtocol`, `VMManagerProtocol`, `KeychainServiceProtocol`)
- **Two init paths** — production default + parameterized for testing
- **Swift Testing** — `@Test`, `#expect`, `@Suite` (not XCTest)
- **os.Logger** via `Log` enum for structured logging
- **No third-party deps** — Virtualization.framework, Security.framework, URLSession only
- **Conventional commits** — `feat:`, `fix:`, `refactor:`, `test:`, etc.

## Job Lifecycle

1. ScaleSetPoller long-polls GitHub per org (5min timeout)
2. JobAvailable → enqueue RunnerJob(.pending)
3. JobDispatcher picks next pending (FIFO, one at a time)
4. Clone base VM disk → configure VZ* → boot VM
5. Guest LaunchDaemon runs `./run.sh --jitconfig` from VirtioFS shared dir
6. JobCompleted → stop VM → delete clone → mark .completed
