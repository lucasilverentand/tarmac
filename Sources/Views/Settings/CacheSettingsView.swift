import SwiftUI

struct CacheSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    var onVMControlConfigurationChanged: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardPageHeader(
                title: "Cache & Diagnostics",
                subtitle: "Performance, warm-worker, local API, and diagnostic retention policies."
            )
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 8)

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

            Section("Warm Runner") {
                Toggle("Prewarm and keep one VM ready", isOn: $viewModel.warmRunnerConfig.isEnabled)

                if viewModel.warmRunnerConfig.isEnabled {
                    Stepper(
                        "Idle shutdown: \(viewModel.warmRunnerConfig.idleShutdownSeconds / 60) min",
                        value: $viewModel.warmRunnerConfig.idleShutdownSeconds,
                        in: 60...7_200,
                        step: 60
                    )

                    Stepper(
                        "Recycle after: \(warmRunnerRecycleLabel)",
                        value: $viewModel.warmRunnerConfig.maxConsecutiveJobs,
                        in: 0...100
                    )

                    Text(
                        "Tarmac boots a VM when polling starts, then injects the GitHub runner and job-specific credentials when work arrives. Completed jobs reuse the same VM until its idle timeout or recycle limit is reached."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }

            Section("Local VM Control API") {
                Toggle("Enable loopback REST control", isOn: vmControlEnabledBinding)

                if viewModel.vmControlConfiguration.isEnabled {
                    Stepper(
                        "Port: \(viewModel.vmControlConfiguration.normalizedPort)",
                        value: vmControlPortBinding,
                        in: 1024...65_535
                    )

                    LabeledContent("Base URL") {
                        Text(viewModel.vmControlConfiguration.baseURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Token") {
                        Text(viewModel.vmControlConfiguration.authToken)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button("Rotate Token") {
                        viewModel.rotateVMControlToken()
                        onVMControlConfigurationChanged?()
                    }

                    Text(
                        "Exposes GET /health, GET /vm, and authenticated POST /vm/boot, /vm/stop, and /vm/teardown on 127.0.0.1 only. Send Authorization: Bearer <token> for lifecycle calls."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
        }
        .onChange(of: viewModel.vmControlConfiguration.isEnabled) { _, _ in
            onVMControlConfigurationChanged?()
        }
        .onChange(of: viewModel.vmControlConfiguration.port) { _, _ in
            onVMControlConfigurationChanged?()
        }
    }

    private var vmControlEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.vmControlConfiguration.isEnabled },
            set: { enabled in
                var configuration = viewModel.vmControlConfiguration
                configuration.isEnabled = enabled
                if enabled {
                    configuration.ensureAuthToken()
                }
                viewModel.vmControlConfiguration = configuration
                onVMControlConfigurationChanged?()
            }
        )
    }

    private var vmControlPortBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.vmControlConfiguration.normalizedPort) },
            set: { port in
                var configuration = viewModel.vmControlConfiguration
                configuration.port = port
                viewModel.vmControlConfiguration = configuration
                onVMControlConfigurationChanged?()
            }
        )
    }

    private var warmRunnerRecycleLabel: String {
        viewModel.warmRunnerConfig.maxConsecutiveJobs == 0
            ? "never"
            : "\(viewModel.warmRunnerConfig.maxConsecutiveJobs) jobs"
    }
}
