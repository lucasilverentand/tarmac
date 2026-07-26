import SwiftUI

struct JobQueueView: View {
    let queueViewModel: QueueViewModel
    let onOpenAccounts: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                QueueHeader(isPolling: queueViewModel.isPolling)
                QueueMetrics(
                    runningCount: queueViewModel.activeJob == nil ? 0 : 1,
                    pendingCount: queueViewModel.pendingJobs.count,
                    completedTodayCount: queueViewModel.completedTodayCount
                )

                if queueViewModel.allJobs.isEmpty {
                    QueueEmptyState(
                        isPolling: queueViewModel.isPolling,
                        onOpenAccounts: onOpenAccounts
                    )
                } else {
                    QueueSections(
                        activeJob: queueViewModel.activeJob,
                        pendingJobs: queueViewModel.pendingJobs,
                        completedJobs: queueViewModel.completedJobs
                    )
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct QueueHeader: View {
    let isPolling: Bool

    var body: some View {
        DashboardPageHeader(
            title: "Runner Queue",
            subtitle: "GitHub Actions jobs waiting for a local macOS worker."
        ) {
            DashboardStatusBadge(
                title: isPolling ? "Listening" : "Paused",
                systemImage: isPolling ? "dot.radiowaves.left.and.right" : "pause.circle.fill",
                tint: isPolling ? .green : .secondary
            )
        }
    }
}

private struct QueueMetrics: View {
    let runningCount: Int
    let pendingCount: Int
    let completedTodayCount: Int

    var body: some View {
        DashboardMetricStrip {
            DashboardMetricItem(
                title: "Running",
                value: "\(runningCount)",
                systemImage: "play.fill",
                tint: .green
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            DashboardMetricItem(
                title: "Pending",
                value: "\(pendingCount)",
                systemImage: "clock.fill",
                tint: .orange
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            DashboardMetricItem(
                title: "Completed today",
                value: "\(completedTodayCount)",
                systemImage: "checkmark.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
    }
}

private struct QueueEmptyState: View {
    let isPolling: Bool
    let onOpenAccounts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: isPolling ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isPolling ? Color.green : Color.secondary)
                    .frame(width: 48, height: 48)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(isPolling ? "Waiting for the next workflow" : "Queue polling is paused")
                        .font(.headline)

                    Text(
                        isPolling
                            ? "Tarmac is listening. Jobs appear here as soon as GitHub requests the configured self-hosted runner labels."
                            : "Review your GitHub account setup to resume receiving jobs."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                QueueAccountsButton(
                    isProminent: !isPolling,
                    action: onOpenAccounts
                )
            }
            .padding(20)

            Divider()

            HStack(alignment: .top, spacing: 16) {
                QueueFlowStep(
                    title: "GitHub queues",
                    detail: "A workflow requests your runner labels.",
                    systemImage: "arrow.down.to.line"
                )
                QueueFlowStep(
                    title: "Tarmac provisions",
                    detail: "A clean virtual Mac starts or a warm worker is claimed.",
                    systemImage: "server.rack"
                )
                QueueFlowStep(
                    title: "The job runs",
                    detail: "Live progress and diagnostics stay visible here.",
                    systemImage: "play.rectangle.on.rectangle"
                )
            }
            .padding(20)
        }
        .dashboardSurface()
    }
}

private struct QueueFlowStep: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct QueueAccountsButton: View {
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        if isProminent {
            Button(action: action) {
                Label("Review Accounts", systemImage: "building.2")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Label("Review Accounts", systemImage: "building.2")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct QueueSections: View {
    let activeJob: RunnerJob?
    let pendingJobs: [RunnerJob]
    let completedJobs: [RunnerJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let activeJob {
                JobSectionView(title: "Running", count: 1) {
                    JobRowView(job: activeJob, isProminent: true)
                }
            }

            JobSectionView(title: "Pending", count: pendingJobs.count) {
                if pendingJobs.isEmpty {
                    EmptySectionText("No pending jobs")
                } else {
                    ForEach(pendingJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }

            JobSectionView(title: "Completed", count: completedJobs.count) {
                if completedJobs.isEmpty {
                    EmptySectionText("No completed jobs")
                } else {
                    ForEach(completedJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }
        }
    }
}

private struct JobSectionView<Content: View>: View {
    let title: LocalizedStringResource
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                Spacer()
            }

            VStack(spacing: 0) {
                content
            }
            .dashboardSurface()
        }
    }
}

private struct EmptySectionText: View {
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}
