import SwiftUI

struct StorageOnboardingView: View {
    let configStore: ConfigStore

    @State private var selectedPath = ConfigStore.defaultStorageDirectoryPath
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Choose Storage Location")
                    .font(.title2.weight(.semibold))

                Text(
                    "Tarmac stores VM images, platform identity, runner work directories, and Actions cache data in one folder."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Storage folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(selectedPath)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseDirectory()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Base image: \(derivedPath("BaseImage.img"))", systemImage: "desktopcomputer")
                    Label("Restore image: \(derivedPath("restore.ipsw"))", systemImage: "arrow.down.circle")
                    Label("Platform identity: \(derivedPath("Platform"))", systemImage: "key")
                    Label("Cache and job data: \(derivedPath("Cache"))", systemImage: "archivebox")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: 520)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            Button("Continue") {
                saveStorageLocation()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: selectedPath).deletingLastPathComponent()

        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
            errorMessage = nil
        }
    }

    private func saveStorageLocation() {
        do {
            try configStore.configureStorage(at: URL(fileURLWithPath: selectedPath))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func derivedPath(_ component: String) -> String {
        URL(fileURLWithPath: selectedPath).appendingPathComponent(component).path
    }
}
