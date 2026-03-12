import SwiftUI

struct JobQueueView: View {
    let queueViewModel: QueueViewModel

    var body: some View {
        List {
            if let activeJob = queueViewModel.activeJob {
                Section("Running") {
                    JobRowView(job: activeJob)
                        .listRowBackground(Color.accentColor.opacity(0.08))
                }
            }

            Section("Pending") {
                if queueViewModel.pendingJobs.isEmpty {
                    Text("No pending jobs")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(queueViewModel.pendingJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }

            Section("Completed") {
                if queueViewModel.completedJobs.isEmpty {
                    Text("No completed jobs")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(queueViewModel.completedJobs) { job in
                        JobRowView(job: job)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if queueViewModel.allJobs.isEmpty {
                ContentUnavailableView(
                    "No jobs in queue",
                    systemImage: "tray",
                    description: Text("Jobs will appear here when workflows request self-hosted runners.")
                )
            }
        }
    }
}
