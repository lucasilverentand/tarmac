import SwiftUI

struct JobRowView: View {
    let job: RunnerJob
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))

                Image(systemName: statusSystemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.workflowName ?? "Job #\(job.id)")
                    .font(.subheadline.weight(isProminent ? .semibold : .medium))
                    .lineLimit(1)

                Text("\(job.organizationName)\(repoSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if job.diagnosticsBundlePath != nil {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .help("Diagnostics available")
            }

            Text(trailingText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isProminent {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            }
        }
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

    private var statusSystemImage: String {
        switch job.status {
        case .pending: "clock.fill"
        case .provisioning: "shippingbox.fill"
        case .running: "play.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
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
