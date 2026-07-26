import SwiftUI

struct AppSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        List(selection: $selection) {
            Section("Activity") {
                ForEach([AppSection.queue, .workers]) { section in
                    SidebarRow(section: section)
                        .tag(section)
                }
            }

            Section("Configuration") {
                ForEach([AppSection.organizations, .cache, .storage]) { section in
                    SidebarRow(section: section)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Tarmac")
    }
}

private struct SidebarRow: View {
    let section: AppSection

    var body: some View {
        Label(section.displayName, systemImage: section.systemImage)
            .lineLimit(1)
    }
}
