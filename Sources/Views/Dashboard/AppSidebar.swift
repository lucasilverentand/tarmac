import SwiftUI

struct AppSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        List(selection: $selection) {
            Section("Activity") {
                row(.queue)
                row(.virtualMachine)
            }

            Section("Configuration") {
                row(.organizations)
                row(.cache)
                row(.storage)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: AppSection) -> some View {
        Label(section.displayName, systemImage: section.systemImage)
            .tag(section)
    }
}
