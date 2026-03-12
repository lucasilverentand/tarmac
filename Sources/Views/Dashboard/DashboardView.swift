import SwiftUI

struct DashboardView: View {
    let appState: AppState

    var body: some View {
        HSplitView {
            JobQueueView(queueViewModel: appState.queueViewModel)
                .frame(minWidth: 400)

            VMStatusCard(
                vmStatusViewModel: appState.vmStatusViewModel,
                vmConfig: appState.configStore.vmConfiguration,
                configStore: appState.configStore
            )
            .frame(width: 300)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
