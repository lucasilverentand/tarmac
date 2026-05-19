import SwiftUI

struct AppSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Activity", items: [.queue, .virtualMachine])
                section("Configuration", items: [.organizations, .cache, .storage])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Tarmac")
    }

    private func section(_ title: String, items: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(items) { section in
                row(section)
            }
        }
    }

    private func row(_ section: AppSection) -> some View {
        Button {
            selection = section
        } label: {
            Label(section.displayName, systemImage: section.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == section ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if selection == section {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
        }
        .accessibilityValue(selection == section ? "Selected" : "")
    }
}
