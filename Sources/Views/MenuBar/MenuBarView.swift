import SwiftUI

struct MenuBarView: View {
    let appState: AppState

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
