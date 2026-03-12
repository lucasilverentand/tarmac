import SwiftUI

struct JobRowView: View {
    let job: RunnerJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.workflowName ?? "Job #\(job.id)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text("\(job.organizationName)\(repoSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(trailingText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var repoSuffix: String {
        if let repo = job.repositoryName {
            return " / \(repo)"
        }
        return ""
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: .yellow
        case .provisioning: .blue
        case .running: .green
        case .completed: .gray
        case .failed: .red
        }
    }

    private var trailingText: String {
        if let duration = job.duration {
            return formatDuration(duration)
        }
        return "Queued \(timeAgo(job.queuedAt))"
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
