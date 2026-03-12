import SwiftUI

struct MenuBarIcon: View {
    let queueViewModel: QueueViewModel

    var body: some View {
        Image(systemName: iconName)
    }

    private var iconName: String {
        if queueViewModel.allJobs.contains(where: { $0.status == .failed }) {
            return "exclamationmark.triangle.fill"
        }
        if queueViewModel.activeJob != nil {
            return "play.circle.fill"
        }
        return "server.rack"
    }
}
