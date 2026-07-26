import SwiftUI

struct MenuBarView: View {
    let appState: AppState
    @State private var displaySource = VMDisplaySource.shared

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            statsSection
            Divider()
            actionButtons
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        Text("Tarmac")
            .font(.headline)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let job = appState.queueViewModel.activeJob {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.workflowName ?? "Job #\(job.id)")
                        .font(.subheadline.weight(.medium))
                    Text(job.organizationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            }
        } else if appState.vmStatusViewModel.activeVMRole == .warmRunnerIdle {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warm runner idle")
                        .font(.subheadline.weight(.medium))
                    if let operation = appState.vmStatusViewModel.idleVMControlOperation {
                        Text(operation.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if appState.vmStatusViewModel.isWarmRunnerPinned {
                        Text("Kept alive until resumed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let shutdownAt = appState.vmStatusViewModel.warmRunnerIdleShutdownAt {
                        Text(shutdownAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.green)
            }
        } else if appState.vmStatusViewModel.readyForJobs {
            Label {
                Text("Idle — waiting for jobs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
            }
        } else {
            Label {
                Text(appState.vmStatusViewModel.readinessStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(appState.configStore.organizations.count) orgs configured")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(appState.queueViewModel.completedTodayCount) jobs completed today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 4) {
            Button {
                appState.selectedSection = .queue
                openWindow(id: "dashboard")
                NSApp.activate()
            } label: {
                Label("Open Dashboard", systemImage: "rectangle.grid.1x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if displaySource.activeVM != nil {
                Button {
                    displaySource.observe()
                    openWindow(id: "vm-display")
                    NSApp.activate()
                } label: {
                    Label("Observe VM", systemImage: "eye")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    displaySource.takeOver()
                    openWindow(id: "vm-display")
                    NSApp.activate()
                } label: {
                    Label("Take Over VM", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if appState.vmStatusViewModel.activeVMRole == .warmRunnerIdle {
                Divider()

                IdleVMMenuControls(
                    isPinned: appState.vmStatusViewModel.isWarmRunnerPinned,
                    operation: appState.vmStatusViewModel.idleVMControlOperation,
                    errorMessage: appState.vmStatusViewModel.idleVMControlErrorMessage,
                    canControl: appState.vmStatusViewModel.canControlIdleVM,
                    onKeepAlive: {
                        appState.keepIdleWarmRunnerAlive()
                    },
                    onResumeAutomaticShutdown: {
                        appState.resumeIdleWarmRunnerAutomaticShutdown()
                    },
                    onRestart: {
                        Task { await appState.restartIdleWarmRunner() }
                    },
                    onShutDown: {
                        Task { await appState.shutDownIdleWarmRunner() }
                    }
                )
            }

            Button {
                appState.selectedSection = .storage
                openWindow(id: "dashboard")
                NSApp.activate()
            } label: {
                Label("Settings...", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

private struct IdleVMMenuControls: View {
    let isPinned: Bool
    let operation: IdleVMControlOperation?
    let errorMessage: String?
    let canControl: Bool
    let onKeepAlive: () -> Void
    let onResumeAutomaticShutdown: () -> Void
    let onRestart: () -> Void
    let onShutDown: () -> Void

    @State private var isConfirmingShutdown = false

    var body: some View {
        VStack(spacing: 4) {
            if let operation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(operation.statusText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }

            Button(action: isPinned ? onResumeAutomaticShutdown : onKeepAlive) {
                Label(
                    isPinned ? "Resume Auto Shutdown" : "Keep Idle VM Alive",
                    systemImage: isPinned ? "timer" : "pin"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canControl)

            Button(action: onRestart) {
                Label("Restart Idle VM", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canControl)

            Button(role: .destructive) {
                isConfirmingShutdown = true
            } label: {
                Label("Shut Down Idle VM…", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!canControl)

            if let errorMessage {
                Text("Control failed: \(errorMessage)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "Shut down the idle machine?",
            isPresented: $isConfirmingShutdown,
            titleVisibility: .visible
        ) {
            Button("Shut Down", role: .destructive, action: onShutDown)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next job will start a fresh machine.")
        }
    }
}
