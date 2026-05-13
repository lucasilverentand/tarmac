import SwiftUI

struct DashboardView: View {
    let appState: AppState

    var body: some View {
        HSplitView {
            JobQueueView(queueViewModel: appState.queueViewModel)
                .frame(minWidth: 520)

            VMStatusCard(
                vmStatusViewModel: appState.vmStatusViewModel,
                vmConfig: appState.configStore.vmConfiguration,
                configStore: appState.configStore
            )
            .frame(minWidth: 320, idealWidth: 340, maxWidth: 380)
        }
        .frame(minWidth: 900, minHeight: 560)
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
