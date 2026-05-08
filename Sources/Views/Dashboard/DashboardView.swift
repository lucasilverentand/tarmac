import SwiftUI

struct DashboardView: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.configStore.hasCompletedStorageSetup {
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
            } else {
                StorageOnboardingView(configStore: appState.configStore)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
