import SwiftUI

struct WorkerSetupSheet: View {
    let vmStatusViewModel: VMStatusViewModel
    let configStore: ConfigStore
    @Bindable var settingsViewModel: SettingsViewModel
    let onSetupChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingImageWizard = false

    var body: some View {
        VStack(spacing: 0) {
            WorkerSetupHeader(onClose: { dismiss() })
            Divider()

            Form {
                WorkerSetupCapacitySection(settingsViewModel: settingsViewModel)
                WorkerSetupImageSection(
                    baseImageExists: vmStatusViewModel.baseImageExists,
                    baseImageVerified: vmStatusViewModel.baseImageVerified,
                    onOpenImageWizard: { showingImageWizard = true }
                )
                WorkerSetupReadinessSection(readiness: vmStatusViewModel.readiness)
                WorkerSetupStorageSection(storageHealth: vmStatusViewModel.storageHealth)
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 570)
        .sheet(isPresented: $showingImageWizard, onDismiss: onSetupChanged) {
            BaseImageWizardView(configStore: configStore)
        }
        .onDisappear(perform: onSetupChanged)
    }
}

private struct WorkerSetupHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Worker Setup")
                    .font(.title2.weight(.semibold))
                Text("Defaults used when Tarmac creates a new virtual Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}

private struct WorkerSetupCapacitySection: View {
    @Bindable var settingsViewModel: SettingsViewModel

    private let maximumCPUCount = max(1, ProcessInfo.processInfo.processorCount)
    private let maximumMemoryGB = max(
        4,
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    )

    var body: some View {
        Section {
            Stepper(
                "CPU cores: \(settingsViewModel.vmConfiguration.cpuCount)",
                value: $settingsViewModel.vmConfiguration.cpuCount,
                in: 1...maximumCPUCount
            )
            Stepper(
                "Memory: \(settingsViewModel.vmConfiguration.memorySizeGB) GB",
                value: $settingsViewModel.vmConfiguration.memorySizeGB,
                in: 4...maximumMemoryGB
            )
            Stepper(
                "Disk capacity: \(settingsViewModel.vmConfiguration.diskSizeGB) GB",
                value: $settingsViewModel.vmConfiguration.diskSizeGB,
                in: 40...500,
                step: 10
            )
            Stepper(
                "Job timeout: \(settingsViewModel.vmConfiguration.runnerCompletionTimeoutSeconds / 60) min",
                value: $settingsViewModel.vmConfiguration.runnerCompletionTimeoutSeconds,
                in: 300...28_800,
                step: 300
            )
        } header: {
            Text("Default capacity")
        } footer: {
            Text("Organization-specific runner profiles can override these defaults.")
        }
    }
}

private struct WorkerSetupImageSection: View {
    let baseImageExists: Bool
    let baseImageVerified: Bool
    let onOpenImageWizard: () -> Void

    var body: some View {
        Section("Base image") {
            LabeledContent("Status") {
                Label(statusTitle, systemImage: statusSystemImage)
                    .foregroundStyle(statusTint)
            }

            Button(action: onOpenImageWizard) {
                Label(
                    baseImageExists ? "Rebuild Base Image…" : "Set Up Base Image…",
                    systemImage: baseImageExists ? "arrow.clockwise.circle" : "arrow.down.circle"
                )
            }
        }
    }

    private var statusTitle: LocalizedStringResource {
        if !baseImageExists {
            return "Missing"
        }
        return baseImageVerified ? "Verified" : "Needs verification"
    }

    private var statusSystemImage: String {
        baseImageExists && baseImageVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusTint: Color {
        baseImageExists && baseImageVerified ? .green : .orange
    }
}

private struct WorkerSetupReadinessSection: View {
    let readiness: RunnerHostReadiness

    var body: some View {
        Section("Readiness") {
            if readiness.isReady {
                Label("Ready to accept jobs", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(readiness.issues) { issue in
                    LabeledContent(issue.category.displayName) {
                        Text(issue.message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }
}

private struct WorkerSetupStorageSection: View {
    let storageHealth: StorageHealth?

    var body: some View {
        Section("Storage") {
            if let storageHealth {
                LabeledContent("Volume", value: storageHealth.volume?.formatDisplayName ?? "Unknown")
                LabeledContent("Clone mode", value: storageHealth.cloneBehavior.displayName)
                if let availableBytes = storageHealth.volume?.availableCapacityBytes {
                    LabeledContent("Available") {
                        Text(availableBytes, format: .byteCount(style: .file))
                    }
                }
            } else {
                Text("Storage has not been checked yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
