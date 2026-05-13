import SwiftUI

struct JobQueueView: View {
    let queueViewModel: QueueViewModel

    var body: some View {
        ScrollView {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 16) {
                    content
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            metrics

            if queueViewModel.allJobs.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                queueSections
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner Queue")
                    .font(.system(.title2, design: .rounded, weight: .semibold))

                Text("GitHub Actions jobs waiting for a local macOS VM runner.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                queueViewModel.isPolling ? "Listening" : "Paused",
                systemImage: queueViewModel.isPolling ? "dot.radiowaves.left.and.right" : "pause.circle"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(queueViewModel.isPolling ? .green : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .dashboardGlassSurface(tint: queueViewModel.isPolling ? .green.opacity(0.12) : nil)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            QueueMetricTile(
                title: "Running",
                value: queueViewModel.activeJob == nil ? "0" : "1",
                systemImage: "play.circle.fill",
                tint: .green
            )
            QueueMetricTile(
                title: "Pending",
                value: "\(queueViewModel.pendingJobs.count)",
                systemImage: "clock.fill",
                tint: .orange
            )
            QueueMetricTile(
                title: "Completed Today",
                value: "\(queueViewModel.completedTodayCount)",
                systemImage: "checkmark.circle.fill",
                tint: .blue
            )
        }
    }

    private var queueSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let activeJob = queueViewModel.activeJob {
                JobSectionView(title: "Running", count: 1) {
                    JobRowView(job: activeJob, isProminent: true)
                }
            }

            JobSectionView(title: "Pending", count: queueViewModel.pendingJobs.count) {
                if queueViewModel.pendingJobs.isEmpty {
                    EmptySectionText("No pending jobs")
                } else {
                    ForEach(queueViewModel.pendingJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }

            JobSectionView(title: "Completed", count: queueViewModel.completedJobs.count) {
                if queueViewModel.completedJobs.isEmpty {
                    EmptySectionText("No completed jobs")
                } else {
                    ForEach(queueViewModel.completedJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("No jobs in queue")
                    .font(.system(.title3, design: .rounded, weight: .semibold))

                Text("Jobs will appear here when workflows request self-hosted runners.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(32)
        .dashboardGlassSurface()
    }
}

private struct QueueMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .dashboardGlassSurface(tint: tint.opacity(0.10))
    }
}

private struct JobSectionView<Content: View>: View {
    let title: String
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
            .dashboardGlassSurface()
        }
    }
}

private struct EmptySectionText: View {
    let text: String

    init(_ text: String) {
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
