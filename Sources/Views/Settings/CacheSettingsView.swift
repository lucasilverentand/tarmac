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

                    LabeledContent("Cache size") {
                        Text(viewModel.cacheSizeDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Storage folder") {
                        Text(viewModel.storageRootPath)
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

                    Text(
                        "The actions/cache directories persist across ephemeral VM runs via a VirtioFS shared mount. The guest VM sees the cache at \(CacheConfiguration.guestMountPoint)."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                Section("Guest Paths") {
                    ForEach(CacheConfiguration.guestCacheTargets, id: \.directoryName) { target in
                        LabeledContent(target.name) {
                            Text(target.guestPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Clear Cache", role: .destructive) {
                        viewModel.clearCache()
                    }
                }
            }

            Section("Diagnostics") {
                Toggle(
                    "Keep full logs for successful jobs",
                    isOn: $viewModel.diagnosticsRetentionConfig.keepSuccessfulJobLogs
                )

                Stepper(
                    "Max bundles: \(viewModel.diagnosticsRetentionConfig.maxBundleCount)",
                    value: $viewModel.diagnosticsRetentionConfig.maxBundleCount,
                    in: 10...500,
                    step: 10
                )

                Stepper(
                    "Retention: \(viewModel.diagnosticsRetentionConfig.maxAgeDays) days",
                    value: $viewModel.diagnosticsRetentionConfig.maxAgeDays,
                    in: 1...90
                )

                Stepper(
                    "Max size: \(viewModel.diagnosticsRetentionConfig.maxSizeMB) MB",
                    value: $viewModel.diagnosticsRetentionConfig.maxSizeMB,
                    in: 64...4096,
                    step: 64
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
