import SwiftUI

struct VMStatusCard: View {
    let vmStatusViewModel: VMStatusViewModel
    let configStore: ConfigStore
    @Bindable var settingsViewModel: SettingsViewModel
    var onWizardDismiss: (() -> Void)? = nil

    @State private var showingImageWizard = false
    @State private var displaySource = VMDisplaySource.shared
    @Environment(\.openWindow) private var openWindow

    private var maxCPU: Int { ProcessInfo.processInfo.processorCount }
    private var maxMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) }

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
        .sheet(isPresented: $showingImageWizard, onDismiss: { onWizardDismiss?() }) {
            BaseImageWizardView(configStore: configStore)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            heroStatus
            readinessSection
            baseImageSection
            resourcesSection
            storageSection
            activeVMSection
            runnerCleanupSection
            imageProfileSection
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var resourcesSection: some View {
        InspectorSection(title: "Resources") {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(
                    "CPU cores: \(settingsViewModel.vmConfiguration.cpuCount)",
                    value: $settingsViewModel.vmConfiguration.cpuCount,
                    in: 1...maxCPU
                )

                Stepper(
                    "Memory: \(settingsViewModel.vmConfiguration.memorySizeGB) GB",
                    value: $settingsViewModel.vmConfiguration.memorySizeGB,
                    in: 4...maxMemoryGB
                )

                Stepper(
                    "Disk size: \(settingsViewModel.vmConfiguration.diskSizeGB) GB",
                    value: $settingsViewModel.vmConfiguration.diskSizeGB,
                    in: 40...500,
                    step: 10
                )

                Stepper(
                    "Runner timeout: \(settingsViewModel.vmConfiguration.runnerCompletionTimeoutSeconds / 60) min",
                    value: $settingsViewModel.vmConfiguration.runnerCompletionTimeoutSeconds,
                    in: 300...28_800,
                    step: 300
                )
            }
            .font(.subheadline)
        }
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
    private var readinessSection: some View {
        InspectorSection(title: "Readiness") {
            VStack(alignment: .leading, spacing: 10) {
                if vmStatusViewModel.readyForJobs {
                    StatusLine(title: "Ready to accept jobs", systemImage: "checkmark.circle.fill", tint: .green)
                } else {
                    ForEach(vmStatusViewModel.readiness.issues) { issue in
                        StatusLine(
                            title: "\(issue.category.displayName): \(issue.message)",
                            systemImage: readinessImage(for: issue.category),
                            tint: readinessTint(for: issue.category)
                        )
                    }
                }
            }
        }
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
                }

                setupBaseImageButton

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
        let title = vmStatusViewModel.baseImageExists ? "Rebuild base image" : "Set up base image"
        let icon = vmStatusViewModel.baseImageExists ? "arrow.clockwise.circle" : "arrow.down.circle"

        if #available(macOS 26.0, *) {
            Button {
                showingImageWizard = true
            } label: {
                Label(title, systemImage: icon)
            }
            .controlSize(.regular)
            .buttonStyle(.glassProminent)
        } else {
            Button {
                showingImageWizard = true
            } label: {
                Label(title, systemImage: icon)
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var activeVMSection: some View {
        InspectorSection(title: "Status") {
            VStack(alignment: .leading, spacing: 10) {
                if let vm = vmStatusViewModel.activeVM {
                    StatusLine(title: "VM running", systemImage: "play.circle.fill", tint: .green)
                    DetailRow(title: "Job ID", value: "\(vm.jobId)")
                    DetailRow(title: "Boot time", value: vm.startedAt.formatted(.relative(presentation: .named)))
                } else {
                    StatusLine(title: "No VM running", systemImage: "stop.circle", tint: .secondary)
                }

                if displaySource.activeVM != nil {
                    Button {
                        openWindow(id: "vm-display")
                    } label: {
                        Label("Show VM display", systemImage: "display")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var runnerCleanupSection: some View {
        let report = vmStatusViewModel.runnerReconciliation
        if report.hasActivity {
            InspectorSection(title: "Runner Cleanup") {
                VStack(alignment: .leading, spacing: 10) {
                    StatusLine(
                        title: report.statusText,
                        systemImage: report.failures.isEmpty
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill",
                        tint: report.failures.isEmpty ? .green : .orange
                    )
                    DetailRow(title: "Scanned", value: "\(report.scannedRunnerCount)")
                    DetailRow(title: "Matched", value: "\(report.matchedLeaseCount)")
                    DetailRow(title: "Removed", value: "\(report.removedRunners.count)")
                    if !report.failures.isEmpty {
                        DetailRow(title: "Failures", value: "\(report.failures.count)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var imageProfileSection: some View {
        let profiles = configStore.organizations.compactMap {
            org -> (organization: Organization, profile: RunnerImageProfile)? in
            guard let profile = org.imageProfile else { return nil }
            return (org, profile)
        }

        if !profiles.isEmpty {
            InspectorSection(title: "Runner Profiles") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(profiles, id: \.organization.id) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            StatusLine(
                                title: "\(item.organization.name): \(item.profile.name)",
                                systemImage: item.profile.isReady
                                    ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                tint: item.profile.isReady ? .green : .orange
                            )

                            if item.profile.isReady {
                                DetailRow(
                                    title: "Labels",
                                    value: item.profile.advertisedLabels.joined(separator: ", ")
                                )
                                if let preparation = item.profile.preparation {
                                    DetailRow(
                                        title: "Prepared",
                                        value: "\(preparation.completedStepCount)/\(preparation.steps.count) steps"
                                    )
                                    if !preparation.baseImageIdentifier.isEmpty {
                                        DetailRow(title: "Image", value: preparation.baseImageIdentifier)
                                    }
                                }
                            } else if let issue = item.profile.readinessIssues.first {
                                Text(issue.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
        vmStatusViewModel.readinessStatusText
    }

    private func readinessImage(for category: RunnerHostReadinessCategory) -> String {
        switch category {
        case .host: "desktopcomputer.trianglebadge.exclamationmark"
        case .storage: "externaldrive.badge.exclamationmark"
        case .vm: "desktopcomputer"
        case .github: "key.horizontal"
        }
    }

    private func readinessTint(for category: RunnerHostReadinessCategory) -> Color {
        switch category {
        case .host, .storage: .red
        case .vm, .github: .orange
        }
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
