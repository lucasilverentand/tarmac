import SwiftUI

struct VMStatusCard: View {
    let vmStatusViewModel: VMStatusViewModel
    let vmConfig: VMConfiguration
    let configStore: ConfigStore

    @State private var showingImageWizard = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 16) {
                    content
                }
            } else {
                content
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingImageWizard) {
            BaseImageWizardView(configStore: configStore)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            heroStatus
            baseImageSection
            storageSection
            activeVMSection
            configurationSection
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Virtual Machine")
                .font(.system(.title3, design: .rounded, weight: .semibold))

            Text("Ephemeral runner host")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var heroStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: vmStatusViewModel.activeVM == nil ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(vmStatusViewModel.activeVM == nil ? "Idle" : "Running")
                    .font(.headline)

                Text(readinessSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .dashboardGlassSurface(tint: statusTint.opacity(0.12))
    }

    @ViewBuilder
    private var baseImageSection: some View {
        InspectorSection(title: "Base Image") {
            VStack(alignment: .leading, spacing: 10) {
                if vmStatusViewModel.baseImageExists {
                    if vmStatusViewModel.baseImageVerified {
                        StatusLine(
                            title: "Base image verified",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                    } else {
                        StatusLine(
                            title: "Base image needs verification",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }
                } else {
                    StatusLine(
                        title: "Base image missing",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )

                    setupBaseImageButton
                }

                if vmStatusViewModel.isInstalling {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: vmStatusViewModel.installProgress)
                            .progressViewStyle(.linear)

                        Text("\(Int(vmStatusViewModel.installProgress * 100))% installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        InspectorSection(title: "Storage") {
            VStack(alignment: .leading, spacing: 10) {
                if let health = vmStatusViewModel.storageHealth {
                    StatusLine(
                        title: "\(health.status.displayName) storage",
                        systemImage: storageStatusImage(for: health),
                        tint: storageStatusColor(for: health)
                    )
                    DetailRow(title: "Volume", value: health.volume?.formatDisplayName ?? "Unknown")
                    DetailRow(title: "Clone", value: health.cloneBehavior.displayName)
                    DetailRow(title: "Free", value: formatBytes(health.volume?.availableCapacityBytes))
                } else {
                    StatusLine(title: "Storage unchecked", systemImage: "questionmark.circle", tint: .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var setupBaseImageButton: some View {
        if #available(macOS 26.0, *) {
            Button {
                showingImageWizard = true
            } label: {
                Label("Set up base image", systemImage: "arrow.down.circle")
            }
            .controlSize(.regular)
            .buttonStyle(.glassProminent)
        } else {
            Button {
                showingImageWizard = true
            } label: {
                Label("Set up base image", systemImage: "arrow.down.circle")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var activeVMSection: some View {
        InspectorSection(title: "Status") {
            if let vm = vmStatusViewModel.activeVM {
                VStack(alignment: .leading, spacing: 10) {
                    StatusLine(title: "VM running", systemImage: "play.circle.fill", tint: .green)
                    DetailRow(title: "Job ID", value: "\(vm.jobId)")
                    DetailRow(title: "Boot time", value: vm.startedAt.formatted(.relative(presentation: .named)))
                }
            } else {
                StatusLine(title: "No VM running", systemImage: "stop.circle", tint: .secondary)
            }
        }
    }

    private var configurationSection: some View {
        InspectorSection(title: "Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow(title: "CPU", value: "\(vmConfig.cpuCount) cores")
                DetailRow(title: "Memory", value: "\(vmConfig.memorySizeGB) GB")
                DetailRow(title: "Disk", value: "\(vmConfig.diskSizeGB) GB")
            }
        }
    }

    private var statusTint: Color {
        if vmStatusViewModel.activeVM != nil {
            return .green
        }
        return vmStatusViewModel.readyForJobs ? .blue : .orange
    }

    private var readinessSubtitle: String {
        if vmStatusViewModel.readyForJobs {
            return "Ready to accept jobs"
        }
        if !vmStatusViewModel.baseImageExists {
            return "Base image setup required"
        }
        if !vmStatusViewModel.baseImageVerified {
            return "Base image verification required"
        }
        if vmStatusViewModel.storageHealth?.status == .blocked {
            return "Storage setup required"
        }
        return "Setup checks need attention"
    }

    private func storageStatusImage(for health: StorageHealth) -> String {
        switch health.status {
        case .fast: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func storageStatusColor(for health: StorageHealth) -> Color {
        switch health.status {
        case .fast: .green
        case .degraded: .orange
        case .blocked: .red
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .dashboardGlassSurface()
    }
}

private struct StatusLine: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "Unknown" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: bytes)
}
