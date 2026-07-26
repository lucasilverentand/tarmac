import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if appState.configStore.hasCompletedStorageSetup {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    AppSidebar(selection: $appState.selectedSection)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                } detail: {
                    DashboardDetailView(appState: appState)
                        .navigationTitle(appState.selectedSection.displayName)
                }
                .navigationSplitViewStyle(.balanced)
                .frame(minWidth: 1000, minHeight: 600)
            } else {
                StorageOnboardingView(configStore: appState.configStore)
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
    }

}

private struct DashboardDetailView: View {
    let appState: AppState

    var body: some View {
        switch appState.selectedSection {
        case .queue:
            JobQueueView(
                queueViewModel: appState.queueViewModel,
                onOpenAccounts: {
                    appState.selectedSection = .organizations
                }
            )
        case .workers:
            WorkersView(appState: appState)
        case .organizations:
            OrganizationListView(viewModel: appState.settingsViewModel)
        case .cache:
            CacheSettingsView(
                viewModel: appState.settingsViewModel,
                onVMControlConfigurationChanged: {
                    appState.syncVMControlServer()
                }
            )
        case .storage:
            StorageSettingsView(viewModel: appState.settingsViewModel)
        }
    }
}
