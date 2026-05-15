import SwiftUI

struct SettingsView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsTab(viewModel: settingsViewModel)
            }

            Tab("Organizations", systemImage: "building.2") {
                OrganizationListView(viewModel: settingsViewModel)
            }

            Tab("Virtual Machine", systemImage: "desktopcomputer") {
                VMSettingsView(viewModel: settingsViewModel)
            }

            Tab("Cache", systemImage: "archivebox") {
                CacheSettingsView(viewModel: settingsViewModel)
            }
        }
        .frame(width: 560, height: 620)
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var storageError: String?

    var body: some View {
        let report = viewModel.storageReport

        Form {
            Toggle("Launch at login", isOn: $viewModel.launchAtLogin)

            LabeledContent("Storage folder") {
                HStack {
                    Text(viewModel.storageRootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Choose...") {
                        chooseDirectory()
                    }
                    .controlSize(.small)
                }
            }

            Toggle("Keep installer after verification", isOn: $viewModel.keepInstallerAfterVerification)

            Section("Storage Health") {
                LabeledContent("Status") {
                    Label(viewModel.storageHealth.status.displayName, systemImage: storageStatusImage)
                        .font(.caption)
                        .foregroundStyle(storageStatusColor)
                }

                LabeledContent("Volume") {
                    pathText(viewModel.storageHealth.volume?.formatDisplayName ?? "Unknown")
                }

                LabeledContent("Clone path") {
                    pathText(viewModel.storageHealth.cloneBehavior.displayName)
                }

                if let mountPoint = viewModel.storageHealth.volume?.mountPoint {
                    LabeledContent("Mount") {
                        pathText(mountPoint)
                    }
                }

                if let retainedInstallerDescription = viewModel.retainedInstallerDescription {
                    LabeledContent("Retained installer") {
                        pathText(retainedInstallerDescription)
                    }
                }

                ForEach(viewModel.storageHealth.issues) { issue in
                    Label(
                        issue.message,
                        systemImage: issue.severity == .blocking
                            ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                }
            }

            Section("Storage Use") {
                LabeledContent("Total managed", value: viewModel.formatStorageBytes(report.totalManagedBytes))
                LabeledContent("Base image", value: viewModel.formatStorageBytes(report.baseImageBytes))
                LabeledContent("Platform data", value: viewModel.formatStorageBytes(report.platformDataBytes))
                LabeledContent(
                    "Installer artifacts",
                    value: viewModel.formatStorageBytes(report.installerArtifactBytes)
                )
                LabeledContent("Job scratch and disks", value: viewModel.formatStorageBytes(report.transientBytes))
                LabeledContent("Diagnostics", value: viewModel.formatStorageBytes(report.diagnosticsBytes))
                LabeledContent("Actions cache", value: viewModel.formatStorageBytes(report.cacheBytes))
                if let freeBytes = report.freeBytes {
                    LabeledContent("Free space", value: viewModel.formatStorageBytes(freeBytes))
                }
            }

            Section("Cleanup") {
                Button("Clear Actions Cache", role: .destructive) {
                    viewModel.clearCache()
                }

                Button("Remove Installer Artifacts", role: .destructive) {
                    viewModel.cleanupInstallerArtifacts()
                }
                .disabled(report.installerArtifactBytes == 0)

                Button("Remove Stale Job Scratch", role: .destructive) {
                    viewModel.cleanupJobScratch()
                }

                Button("Remove Stale Cloned Disks", role: .destructive) {
                    viewModel.cleanupDebugDisks()
                }
            }

            if let storageError {
                Label(storageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section("Derived Paths") {
                LabeledContent("Base image") {
                    pathText(viewModel.baseImagePath)
                }
                LabeledContent("Restore image") {
                    pathText(viewModel.restoreImagePath)
                }
                LabeledContent("Platform identity") {
                    pathText(viewModel.platformDirectoryPath)
                }
                LabeledContent("Actions cache") {
                    pathText(viewModel.resolvedCachePath)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            viewModel.refreshStorageHealth()
        }
    }

    private var storageStatusImage: String {
        switch viewModel.storageHealth.status {
        case .fast: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private var storageStatusColor: Color {
        switch viewModel.storageHealth.status {
        case .fast: .green
        case .degraded: .orange
        case .blocked: .red
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.configureStorage(at: url)
                storageError = nil
            } catch {
                storageError = error.localizedDescription
            }
        }
    }
}
