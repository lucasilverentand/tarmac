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
                    detailView
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

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSection {
        case .queue:
            JobQueueView(queueViewModel: appState.queueViewModel)
        case .virtualMachine:
            ScrollView {
                VMStatusCard(
                    vmStatusViewModel: appState.vmStatusViewModel,
                    configStore: appState.configStore,
                    settingsViewModel: appState.settingsViewModel,
                    onWizardDismiss: {
                        appState.refreshReadiness()
                        Task { await appState.start() }
                    }
                )
            }
        case .organizations:
            OrganizationListView(viewModel: appState.settingsViewModel)
        case .cache:
            CacheSettingsView(viewModel: appState.settingsViewModel)
        case .storage:
            StorageSettingsView(viewModel: appState.settingsViewModel)
        }
    }
}

extension View {
    @ViewBuilder
    func dashboardGlassSurface(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                Glass.regular
                    .tint(tint)
                    .interactive(interactive),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            self
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.quaternary)
                }
        }
    }
}
