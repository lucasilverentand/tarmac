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
        .frame(width: 520, height: 480)
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $viewModel.launchAtLogin)

            LabeledContent("Cache directory") {
                HStack {
                    Text(viewModel.cacheDirectoryPath)
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
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.cacheDirectoryPath = url.path
        }
    }
}
