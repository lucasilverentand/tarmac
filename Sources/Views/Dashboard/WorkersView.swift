import AppKit
import SwiftUI

struct WorkersView: View {
    let appState: AppState

    @State private var selectedWorkerID: WorkerSnapshot.ID?
    @State private var showingWorkerSetup = false
    @State private var displaySource = VMDisplaySource.shared

    var body: some View {
        WorkersPageContent(
            workers: appState.vmStatusViewModel.workers,
            runnerPools: appState.configStore.organizations.flatMap(\.effectiveRunnerPools),
            activeWorkerCount: appState.vmStatusViewModel.activeWorkerCount,
            workingWorkerCount: appState.vmStatusViewModel.workingWorkerCount,
            warmIdleWorkerCount: appState.vmStatusViewModel.warmIdleWorkerCount,
            readinessStatus: appState.vmStatusViewModel.readinessStatusText,
            readyForJobs: appState.vmStatusViewModel.readyForJobs,
            selectedWorkerID: $selectedWorkerID,
            canDisplayVM: displaySource.hasActiveDisplay,
            idleVMControlOperation: appState.vmStatusViewModel.idleVMControlOperation,
            idleVMControlErrorMessage: appState.vmStatusViewModel.idleVMControlErrorMessage,
            canControlIdleVM: appState.vmStatusViewModel.canControlIdleVM,
            onOpenSetup: { showingWorkerSetup = true },
            onObserve: {
                displaySource.observe()
                openVMDisplay()
            },
            onTakeOver: {
                displaySource.takeOver()
                openVMDisplay()
            },
            onKeepAlive: {
                appState.keepIdleWarmRunnerAlive(workerID: selectedWorkerID)
            },
            onResumeAutomaticShutdown: {
                appState.resumeIdleWarmRunnerAutomaticShutdown(workerID: selectedWorkerID)
            },
            onRestart: {
                Task { await appState.restartIdleWarmRunner(workerID: selectedWorkerID) }
            },
            onShutDown: {
                Task { await appState.shutDownIdleWarmRunner(workerID: selectedWorkerID) }
            }
        )
        .toolbar {
            ToolbarItem {
                Button {
                    appState.refreshWorkers()
                } label: {
                    Label("Refresh Workers", systemImage: "arrow.clockwise")
                }
                .help("Refresh worker state and resource usage")
            }

            ToolbarItem {
                Button {
                    showingWorkerSetup = true
                } label: {
                    Label("Worker Setup", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingWorkerSetup) {
            WorkerSetupSheet(
                vmStatusViewModel: appState.vmStatusViewModel,
                configStore: appState.configStore,
                settingsViewModel: appState.settingsViewModel,
                onSetupChanged: {
                    appState.refreshReadiness()
                    Task { await appState.start() }
                }
            )
        }
        .task {
            while !Task.isCancelled {
                appState.refreshWorkers()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @Environment(\.openWindow) private var openWindow

    private func openVMDisplay() {
        openWindow(id: "vm-display")
        NSApp.activate()
    }
}

private struct WorkersPageContent: View {
    let workers: [WorkerSnapshot]
    let runnerPools: [RunnerPoolConfiguration]
    let activeWorkerCount: Int
    let workingWorkerCount: Int
    let warmIdleWorkerCount: Int
    let readinessStatus: String
    let readyForJobs: Bool
    @Binding var selectedWorkerID: WorkerSnapshot.ID?
    let canDisplayVM: Bool
    let idleVMControlOperation: IdleVMControlOperation?
    let idleVMControlErrorMessage: String?
    let canControlIdleVM: Bool
    let onOpenSetup: () -> Void
    let onObserve: () -> Void
    let onTakeOver: () -> Void
    let onKeepAlive: () -> Void
    let onResumeAutomaticShutdown: () -> Void
    let onRestart: () -> Void
    let onShutDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkersHeader(activeWorkerCount: activeWorkerCount)
            WorkersSummaryBar(
                activeWorkerCount: activeWorkerCount,
                workingWorkerCount: workingWorkerCount,
                warmIdleWorkerCount: warmIdleWorkerCount,
                allocatedCPUCount: workers.reduce(0) {
                    $0 + ($1.lifecycleState.isActive ? $1.configuration.cpuCount : 0)
                },
                allocatedMemoryGB: workers.reduce(0) {
                    $0 + ($1.lifecycleState.isActive ? $1.configuration.memorySizeGB : 0)
                }
            )

            if !runnerPools.isEmpty {
                RunnerPoolStrip(pools: runnerPools, workers: workers)
            }

            if workers.isEmpty {
                WorkersEmptyState(
                    readinessStatus: readinessStatus,
                    readyForJobs: readyForJobs,
                    onOpenSetup: onOpenSetup
                )
            } else {
                WorkerInventoryWorkspace(
                    workers: workers,
                    selectedWorkerID: $selectedWorkerID,
                    canDisplayVM: canDisplayVM,
                    idleVMControlOperation: idleVMControlOperation,
                    idleVMControlErrorMessage: idleVMControlErrorMessage,
                    canControlIdleVM: canControlIdleVM,
                    onObserve: onObserve,
                    onTakeOver: onTakeOver,
                    onKeepAlive: onKeepAlive,
                    onResumeAutomaticShutdown: onResumeAutomaticShutdown,
                    onRestart: onRestart,
                    onShutDown: onShutDown
                )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            synchronizeSelection()
        }
        .onChange(of: workers.map(\.id)) {
            synchronizeSelection()
        }
    }

    private func synchronizeSelection() {
        guard !workers.isEmpty else {
            selectedWorkerID = nil
            return
        }
        if let selectedWorkerID, workers.contains(where: { $0.id == selectedWorkerID }) {
            return
        }
        selectedWorkerID = workers.first?.id
    }
}

private struct RunnerPoolStrip: View {
    let pools: [RunnerPoolConfiguration]
    let workers: [WorkerSnapshot]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(pools) { pool in
                let worker = workers.first { $0.runnerPoolID == pool.id }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            pool.displayName,
                            systemImage: pool.releaseChannel == .appStore ? "shippingbox" : "testtube.2"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status(for: pool, worker: worker))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: pool, worker: worker))
                    }
                    Text("macOS \(pool.imageProfile.baseMacOSVersion) · Xcode \(pool.imageProfile.xcodeVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pool.routingLabels.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardSurface(tint: tint(for: pool, worker: worker))
            }
        }
    }

    private func status(for pool: RunnerPoolConfiguration, worker: WorkerSnapshot?) -> String {
        if !pool.isEnabled { return "Setup required" }
        if worker?.lifecycleState == .warmIdle { return "Warm" }
        if worker != nil { return "Active" }
        return "Cold"
    }

    private func tint(for pool: RunnerPoolConfiguration, worker: WorkerSnapshot?) -> Color {
        if !pool.isEnabled { return .orange }
        if worker?.lifecycleState == .warmIdle { return .green }
        return worker == nil ? .secondary : .blue
    }
}

private struct WorkersHeader: View {
    let activeWorkerCount: Int

    var body: some View {
        DashboardPageHeader(
            title: "Workers",
            subtitle: "Virtual Macs owned by Tarmac, their work, health, and resource use."
        ) {
            DashboardStatusBadge(
                title: activeWorkerCount > 0 ? "Live" : "No active workers",
                systemImage: activeWorkerCount > 0 ? "circle.fill" : "circle.dashed",
                tint: activeWorkerCount > 0 ? .green : .secondary
            )
        }
    }
}

private struct WorkersSummaryBar: View {
    let activeWorkerCount: Int
    let workingWorkerCount: Int
    let warmIdleWorkerCount: Int
    let allocatedCPUCount: Int
    let allocatedMemoryGB: Int

    var body: some View {
        DashboardMetricStrip {
            DashboardMetricItem(
                title: "Active",
                value: "\(activeWorkerCount)",
                systemImage: "server.rack",
                tint: activeWorkerCount > 0 ? .green : .secondary
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            DashboardMetricItem(
                title: "Working",
                value: "\(workingWorkerCount)",
                systemImage: "hammer.fill",
                tint: .green
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            DashboardMetricItem(
                title: "Warm & idle",
                value: "\(warmIdleWorkerCount)",
                systemImage: "flame.fill",
                tint: .orange
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            DashboardMetricItem(
                title: "Allocated",
                value: "\(allocatedCPUCount) CPU · \(allocatedMemoryGB) GB",
                systemImage: "gauge.with.dots.needle.67percent"
            )
            .frame(maxWidth: .infinity)
        }
    }
}

private struct WorkersEmptyState: View {
    let readinessStatus: String
    let readyForJobs: Bool
    let onOpenSetup: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(readyForJobs ? Color.blue : Color.orange)
                .frame(width: 52, height: 52)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("No active workers")
                    .font(.headline)
                Text(readyForJobs ? "Tarmac is ready and waiting for the next job." : readinessStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }

            Spacer(minLength: 20)

            WorkerSetupActionButton(
                isProminent: !readyForJobs,
                action: onOpenSetup
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface(tint: readyForJobs ? .blue : .orange)
    }
}

private struct WorkerSetupActionButton: View {
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        if isProminent {
            Button(action: action) {
                Label("Worker Setup", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Label("Worker Setup", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct WorkerInventoryWorkspace: View {
    let workers: [WorkerSnapshot]
    @Binding var selectedWorkerID: WorkerSnapshot.ID?
    let canDisplayVM: Bool
    let idleVMControlOperation: IdleVMControlOperation?
    let idleVMControlErrorMessage: String?
    let canControlIdleVM: Bool
    let onObserve: () -> Void
    let onTakeOver: () -> Void
    let onKeepAlive: () -> Void
    let onResumeAutomaticShutdown: () -> Void
    let onRestart: () -> Void
    let onShutDown: () -> Void

    var body: some View {
        HSplitView {
            WorkerInventoryList(workers: workers, selectedWorkerID: $selectedWorkerID)
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            if let worker = workers.first(where: { $0.id == selectedWorkerID }) {
                ScrollView {
                    WorkerDetailView(
                        worker: worker,
                        canDisplayVM: canDisplayVM,
                        idleVMControlOperation: idleVMControlOperation,
                        idleVMControlErrorMessage: idleVMControlErrorMessage,
                        canControlIdleVM: worker.lifecycleState == .warmIdle && idleVMControlOperation == nil,
                        onObserve: onObserve,
                        onTakeOver: onTakeOver,
                        onKeepAlive: onKeepAlive,
                        onResumeAutomaticShutdown: onResumeAutomaticShutdown,
                        onRestart: onRestart,
                        onShutDown: onShutDown
                    )
                    .padding(.leading, 14)
                }
                .frame(minWidth: 430)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WorkerInventoryList: View {
    let workers: [WorkerSnapshot]
    @Binding var selectedWorkerID: WorkerSnapshot.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active VMs")
                    .font(.headline)
                Spacer()
                Text("\(workers.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2)

            List(selection: $selectedWorkerID) {
                ForEach(workers) { worker in
                    WorkerInventoryRow(worker: worker)
                        .tag(worker.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardSurface()
    }
}

private struct WorkerInventoryRow: View {
    let worker: WorkerSnapshot

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(worker.lifecycleState.tint.opacity(0.14))
                Image(systemName: worker.lifecycleState.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(worker.lifecycleState.tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(worker.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 0) {
                    if let releaseChannel = worker.releaseChannel {
                        Text(releaseChannel.displayName)
                        Text(" · ")
                    }
                    Text(worker.lifecycleState.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

private struct WorkerDetailView: View {
    let worker: WorkerSnapshot
    let canDisplayVM: Bool
    let idleVMControlOperation: IdleVMControlOperation?
    let idleVMControlErrorMessage: String?
    let canControlIdleVM: Bool
    let onObserve: () -> Void
    let onTakeOver: () -> Void
    let onKeepAlive: () -> Void
    let onResumeAutomaticShutdown: () -> Void
    let onRestart: () -> Void
    let onShutDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkerDetailHeader(worker: worker)
                .padding(.bottom, 16)

            Divider()

            WorkerResourcesSection(worker: worker)
                .padding(.vertical, 16)

            if let task = worker.task, worker.lifecycleState != .warmIdle {
                Divider()
                WorkerTaskCard(task: task)
                    .padding(.vertical, 16)
            }

            if worker.lifecycleState == .warmIdle {
                Divider()
                WarmWorkerActivityCard(worker: worker)
                    .padding(.vertical, 16)
            }

            Divider()
            WorkerLifecycleCard(worker: worker)
                .padding(.vertical, 16)

            Divider()
            WorkerActionsCard(
                worker: worker,
                canDisplayVM: canDisplayVM,
                operation: idleVMControlOperation,
                errorMessage: idleVMControlErrorMessage,
                canControlIdleVM: canControlIdleVM,
                onObserve: onObserve,
                onTakeOver: onTakeOver,
                onKeepAlive: onKeepAlive,
                onResumeAutomaticShutdown: onResumeAutomaticShutdown,
                onRestart: onRestart,
                onShutDown: onShutDown
            )
            .padding(.top, 16)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardSurface()
    }
}

private struct WorkerDetailHeader: View {
    let worker: WorkerSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: worker.kind == .githubRunner ? "desktopcomputer" : "terminal")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(worker.lifecycleState.tint)
                .frame(width: 48, height: 48)
                .background(
                    worker.lifecycleState.tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(worker.displayName)
                    .font(.title2.weight(.semibold))
                WorkerStateDescription(worker: worker)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !worker.routingLabels.isEmpty {
                    Text(worker.routingLabels.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Label(worker.lifecycleState.title, systemImage: worker.lifecycleState.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(worker.lifecycleState.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(worker.lifecycleState.tint.opacity(0.10), in: Capsule())
        }
    }
}

private struct WorkerStateDescription: View {
    let worker: WorkerSnapshot

    var body: some View {
        VStack(alignment: .leading) {
            switch worker.lifecycleState {
            case .starting:
                if let task = worker.task {
                    Text("Starting for job #\(task.id)")
                } else {
                    Text("Starting the virtual Mac")
                }
            case .working:
                if let workflowName = worker.task?.workflowName {
                    Text("Running \(workflowName)")
                } else if let jobId = worker.jobId {
                    Text("Executing GitHub Actions job #\(jobId)")
                } else {
                    Text("Preparing GitHub Actions runner")
                }
            case .warmIdle:
                Text("Warm and ready for the next queued job")
            case .running:
                Text("Running under local VM control")
            case .stopping:
                Text("Stopping the virtual Mac and cleaning up")
            case .stopped:
                Text("Stopped and awaiting teardown")
            case .failed:
                Text("The worker failed during its VM lifecycle")
            }
        }
    }
}

private struct WorkerResourcesSection: View {
    let worker: WorkerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Resource usage")
                    .font(.headline)
                Spacer()
                if let usage = worker.resourceUsage {
                    Label {
                        Text(usage.sampledAt, style: .relative)
                    } icon: {
                        Image(systemName: usage.isStale() ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                    }
                    .font(.caption)
                    .foregroundStyle(usage.isStale() ? Color.orange : Color.secondary)
                } else {
                    Text("Waiting for guest telemetry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                WorkerCPUUsageCard(
                    cpuPercent: worker.resourceUsage?.normalizedCPUPercent,
                    allocatedCPUCount: worker.configuration.cpuCount
                )
                WorkerMemoryUsageCard(
                    usedBytes: worker.resourceUsage?.memoryUsedBytes,
                    totalBytes: worker.resourceUsage?.memoryTotalBytes,
                    allocatedMemoryGB: worker.configuration.memorySizeGB
                )
                WorkerDiskUsageCard(
                    usedBytes: worker.resourceUsage?.diskUsedBytes,
                    totalBytes: worker.resourceUsage?.diskTotalBytes,
                    configuredDiskGB: worker.configuration.diskSizeGB,
                    hostAllocatedBytes: worker.diskImageAllocatedBytes
                )
            }
        }
    }
}

private struct WorkerCPUUsageCard: View {
    let cpuPercent: Double?
    let allocatedCPUCount: Int

    var body: some View {
        WorkerResourceCard(title: "CPU", systemImage: "cpu", tint: .secondary) {
            Text(cpuPercent.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            ProgressView(value: cpuPercent ?? 0, total: 100)
                .tint(.accentColor)
            Text("\(allocatedCPUCount) virtual cores allocated")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkerMemoryUsageCard: View {
    let usedBytes: Int64?
    let totalBytes: Int64?
    let allocatedMemoryGB: Int

    var body: some View {
        WorkerResourceCard(title: "Memory", systemImage: "memorychip", tint: .secondary) {
            if let usedBytes, let totalBytes, totalBytes > 0 {
                Text(usedBytes, format: .byteCount(style: .memory))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: Double(usedBytes), total: Double(totalBytes))
                    .tint(.accentColor)
            } else {
                Text("—")
                    .font(.title3.weight(.semibold))
                ProgressView(value: 0, total: 1)
                    .tint(.accentColor)
            }
            Text("\(allocatedMemoryGB) GB allocated")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkerDiskUsageCard: View {
    let usedBytes: Int64?
    let totalBytes: Int64?
    let configuredDiskGB: Int
    let hostAllocatedBytes: Int64?

    var body: some View {
        WorkerResourceCard(title: "Disk", systemImage: "internaldrive", tint: .secondary) {
            if let usedBytes, let totalBytes, totalBytes > 0 {
                Text(usedBytes, format: .byteCount(style: .file))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: Double(usedBytes), total: Double(totalBytes))
                    .tint(.accentColor)
            } else {
                Text("—")
                    .font(.title3.weight(.semibold))
                ProgressView(value: 0, total: 1)
                    .tint(.accentColor)
            }
            if let hostAllocatedBytes {
                Text(
                    "\(hostAllocatedBytes, format: .byteCount(style: .file)) on host · \(configuredDiskGB) GB capacity"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("\(configuredDiskGB) GB capacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkerResourceCard<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WorkerTaskCard: View {
    let task: WorkerTaskSummary

    var body: some View {
        WorkerDetailCard(title: "Current task", systemImage: "hammer.fill") {
            WorkerDetailRow(title: "Workflow", value: task.workflowName ?? "Job #\(task.id)")
            WorkerDetailRow(title: "Repository", value: task.repositoryName ?? "Not reported")
            WorkerDetailRow(title: "Account", value: task.organizationName)
            WorkerDetailRow(title: "Job ID", value: "\(task.id)")
            if let startedAt = task.startedAt {
                HStack {
                    Text("Running")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(startedAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

private struct WarmWorkerActivityCard: View {
    let worker: WorkerSnapshot

    var body: some View {
        WorkerDetailCard(title: "Warm runner", systemImage: "flame.fill") {
            WorkerDetailRow(title: "Jobs served", value: "\(worker.warmRunnerJobsServed ?? 0)")
            if let jobId = worker.jobId {
                WorkerDetailRow(title: "Last job ID", value: "\(jobId)")
            } else {
                WorkerDetailRow(title: "Runner state", value: "Prewarmed")
            }
            if let lastActivityAt = worker.warmRunnerLastActivityAt {
                HStack {
                    Text("Last activity")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastActivityAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption)
            }
            if worker.isPinned {
                Label("Automatic shutdown paused", systemImage: "pin.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if let automaticShutdownAt = worker.automaticShutdownAt {
                HStack {
                    Label("Automatic shutdown", systemImage: "timer")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(automaticShutdownAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

private struct WorkerLifecycleCard: View {
    let worker: WorkerSnapshot

    var body: some View {
        WorkerDetailCard(title: "Virtual machine", systemImage: "desktopcomputer") {
            WorkerDetailRow(title: "VM ID", value: worker.id.uuidString)
            WorkerDetailRow(title: "VM state", value: worker.vmState.rawValue.capitalized)
            if let jobId = worker.jobId {
                WorkerDetailRow(title: "Job ID", value: "\(jobId)")
            }
            HStack {
                Text("Started")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(worker.startedAt, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption)
            WorkerDetailRow(title: "Disk image", value: worker.diskImagePath.lastPathComponent)
        }
    }
}

private struct WorkerActionsCard: View {
    let worker: WorkerSnapshot
    let canDisplayVM: Bool
    let operation: IdleVMControlOperation?
    let errorMessage: String?
    let canControlIdleVM: Bool
    let onObserve: () -> Void
    let onTakeOver: () -> Void
    let onKeepAlive: () -> Void
    let onResumeAutomaticShutdown: () -> Void
    let onRestart: () -> Void
    let onShutDown: () -> Void

    @State private var confirmingShutdown = false

    var body: some View {
        WorkerDetailCard(title: "Controls", systemImage: "slider.horizontal.3") {
            if canDisplayVM {
                HStack(spacing: 8) {
                    Button(action: onObserve) {
                        Label("Observe", systemImage: "eye")
                    }
                    Button(action: onTakeOver) {
                        Label("Take Over", systemImage: "keyboard")
                    }
                }
                .buttonStyle(.bordered)
            }

            if worker.lifecycleState == .warmIdle {
                if let operation {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(operation.statusText)
                            .font(.caption.weight(.medium))
                    }
                }

                ViewThatFits {
                    HStack(spacing: 8) {
                        idleControlButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        idleControlButtons
                    }
                }
                .disabled(!canControlIdleVM)

                if let errorMessage {
                    Label("Control failed: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if !canDisplayVM {
                Text("Controls become available when the VM reaches a controllable state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Shut down the idle worker?",
            isPresented: $confirmingShutdown,
            titleVisibility: .visible
        ) {
            Button("Shut Down", role: .destructive, action: onShutDown)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The warm VM will be removed. The next job will start a fresh worker.")
        }
    }

    @ViewBuilder
    private var idleControlButtons: some View {
        Button(action: worker.isPinned ? onResumeAutomaticShutdown : onKeepAlive) {
            Label(
                worker.isPinned ? "Resume Auto Shutdown" : "Keep Alive",
                systemImage: worker.isPinned ? "timer" : "pin"
            )
        }
        Button(action: onRestart) {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            confirmingShutdown = true
        } label: {
            Label("Shut Down…", systemImage: "power")
        }
    }
}

private struct WorkerDetailCard<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WorkerDetailRow: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private extension WorkerLifecycleState {
    var title: LocalizedStringResource {
        switch self {
        case .starting: "Starting up"
        case .working: "Working"
        case .warmIdle: "Warm & idle"
        case .running: "Running"
        case .stopping: "Shutting down"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .starting: "progress.indicator"
        case .working: "hammer.fill"
        case .warmIdle: "flame.fill"
        case .running: "play.fill"
        case .stopping: "stop.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .starting: .blue
        case .working: .green
        case .warmIdle: .orange
        case .running: .teal
        case .stopping: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}
