import SwiftUI

struct CacheSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Actions Cache") {
                Toggle("Enable persistent cache", isOn: $viewModel.cacheConfig.isEnabled)

                if viewModel.cacheConfig.isEnabled {
                    Stepper(
                        "Max size: \(viewModel.cacheConfig.maxSizeGB) GB",
                        value: $viewModel.cacheConfig.maxSizeGB,
                        in: 5...200,
                        step: 5
                    )

                    Stepper(
                        "Retention: \(viewModel.cacheConfig.retentionDays) days",
                        value: $viewModel.cacheConfig.retentionDays,
                        in: 1...90
                    )
                }
            }

            if viewModel.cacheConfig.isEnabled {
                Section("Info") {
                    LabeledContent("Cache directory") {
                        Text(viewModel.resolvedCachePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    LabeledContent("Guest mount point") {
                        Text(CacheConfiguration.guestMountPoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Text("The actions/cache directories persist across ephemeral VM runs via a VirtioFS shared mount. The guest VM sees the cache at \(CacheConfiguration.guestMountPoint).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    Button("Clear Cache", role: .destructive) {
                        viewModel.clearCache()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
