import SwiftUI

struct OrganizationListView: View {
    let viewModel: SettingsViewModel

    @State private var showingAddSheet = false
    @State private var editingOrg: Organization?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.organizations.isEmpty {
                emptyState
            } else {
                orgList
            }

            Divider()

            HStack {
                if !viewModel.organizations.isEmpty {
                    Text("Drag to set priority — top org is dispatched first")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Add Organization...") {
                    showingAddSheet = true
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingAddSheet) {
            OrganizationFormSheet(viewModel: viewModel)
        }
        .sheet(item: $editingOrg) { org in
            OrganizationFormSheet(viewModel: viewModel, existing: org)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Organizations",
            systemImage: "building.2",
            description: Text("Add a GitHub organization to start receiving runner jobs.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var orgList: some View {
        List {
            ForEach(viewModel.organizations) { org in
                OrganizationRow(
                    org: org,
                    position: position(of: org),
                    setupCheck: viewModel.setupCheckResult(for: org),
                    isCheckingSetup: viewModel.isSetupCheckRunning(for: org),
                    onToggle: { updated in
                        viewModel.updateOrganization(updated)
                    },
                    onRunSetupCheck: { org in
                        await viewModel.runGitHubSetupCheck(for: org)
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingOrg = org }
                .contextMenu {
                    Button("Edit...") { editingOrg = org }
                    Divider()
                    Button("Delete", role: .destructive) { viewModel.removeOrganization(org) }
                }
            }
            .onMove { source, destination in
                viewModel.moveOrganization(fromOffsets: source, toOffset: destination)
            }
        }
    }

    private func position(of org: Organization) -> Int {
        (viewModel.organizations.firstIndex(where: { $0.id == org.id }) ?? 0) + 1
    }
}

// MARK: - Row

private struct OrganizationRow: View {
    let org: Organization
    let position: Int
    let setupCheck: GitHubSetupCheckResult?
    let isCheckingSetup: Bool
    let onToggle: (Organization) -> Void
    let onRunSetupCheck: (Organization) async -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Priority badge
            Text("\(position)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(org.isEnabled ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(org.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(org.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(org.isEnabled ? .primary : .secondary)

                    if !org.isEnabled {
                        Text("disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Label("App \(org.appId.isEmpty ? "—" : org.appId)", systemImage: "app.badge")

                    Text("·")

                    if let scaleSetId = org.scaleSetId {
                        Label("Scale set \(scaleSetId)", systemImage: "server.rack")
                    } else {
                        Label("No scale set", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    Text("·")

                    filterSummary
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Labels
                if !org.runnerLabels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(org.runnerLabels, id: \.self) { label in
                            Text(label)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                imageProfileStatus
                setupCheckStatus
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { org.isEnabled },
                        set: { enabled in
                            var updated = org
                            updated.isEnabled = enabled
                            onToggle(updated)
                        }
                    )
                )
                .labelsHidden()

                Button {
                    Task { await onRunSetupCheck(org) }
                } label: {
                    if isCheckingSetup {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Check Setup", systemImage: "checklist")
                    }
                }
                .controlSize(.small)
                .disabled(isCheckingSetup || !org.isEnabled)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var imageProfileStatus: some View {
        if let profile = org.imageProfile {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    profile.isReady
                        ? "\(profile.name) profile ready"
                        : profile.readinessIssues.first?.message ?? "Profile unavailable",
                    systemImage: profile.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(profile.isReady ? .green : .orange)

                if !profile.advertisedLabels.isEmpty {
                    Text("Profile labels: \(profile.advertisedLabels.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var filterSummary: some View {
        switch org.filterMode {
        case .all:
            Label("All repos", systemImage: "tray.full")
        case .include:
            Label("\(org.filteredRepositories.count) repo(s)", systemImage: "line.3.horizontal.decrease.circle")
        case .exclude:
            Label("Excluding \(org.filteredRepositories.count)", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private var setupCheckStatus: some View {
        if let setupCheck {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    setupCheck.statusText,
                    systemImage: setupCheck.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(setupCheck.isReady ? .green : .orange)

                if !setupCheck.advertisedLabels.isEmpty || !setupCheck.runnerGroupNames.isEmpty {
                    HStack(spacing: 8) {
                        if !setupCheck.advertisedLabels.isEmpty {
                            Text("Advertises \(setupCheck.advertisedLabels.joined(separator: ", "))")
                        }
                        if !setupCheck.runnerGroupNames.isEmpty {
                            Text("Runner groups: \(setupCheck.runnerGroupNames.joined(separator: ", "))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Form Sheet

private struct OrganizationFormSheet: View {
    let viewModel: SettingsViewModel
    var existing: Organization?

    @State private var name: String = ""
    @State private var appId: String = ""
    @State private var installationId: String = ""
    @State private var scaleSetId: String = ""
    @State private var labels: String = "self-hosted, macOS, ARM64"
    @State private var imageProfileEnabled = false
    @State private var imageProfileName = "Apple Platform"
    @State private var baseMacOSVersion = ""
    @State private var xcodeVersion = ""
    @State private var developerDirectory = ""
    @State private var commandLineToolsInstalled = false
    @State private var selectedCapabilities: Set<AppleBuildCapability> = []
    @State private var sdkList = ""
    @State private var simulatorRuntimeList = ""
    @State private var distributionNotarytoolInstalled = false
    @State private var distributionProductbuildInstalled = false
    @State private var distributionPkgbuildInstalled = false
    @State private var distributionHdiutilInstalled = false
    @State private var distributionStaplerInstalled = false
    @State private var distributionDeveloperIDApplicationIdentity = ""
    @State private var distributionDeveloperIDInstallerIdentity = ""
    @State private var distributionCredentialSource: AppleNotarizationCredentialSource = .jobEnvironment
    @State private var distributionCredentialsConfigured = false
    @State private var filterMode: RepositoryFilterMode = .all
    @State private var repositoryList: String = ""
    @State private var hasKey: Bool = false
    @State private var showingFileImporter = false
    @State private var importError: String?

    @Environment(\.dismiss) private var dismiss

    var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Organization" : "Add Organization")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ScrollView {
                Form {
                    Section("Connection") {
                        TextField("Organization name", text: $name)
                            .disabled(isEditing)
                        TextField("Installation ID", text: $installationId)
                        TextField("Scale Set ID", text: $scaleSetId)
                            .help("The numeric ID of your Actions Runner Scale Set for this org")
                    }

                    Section("GitHub App Credentials") {
                        TextField("App ID", text: $appId)

                        HStack {
                            if hasKey {
                                Label("Private key imported", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.subheadline)
                            } else {
                                Label("No key imported", systemImage: "xmark.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }

                            Spacer()

                            if hasKey {
                                Button("Remove", role: .destructive) {
                                    if let org = existing {
                                        viewModel.deletePrivateKey(for: org)
                                        hasKey = false
                                    }
                                }
                                .controlSize(.small)
                            }

                            Button("Import .pem file...") {
                                showingFileImporter = true
                            }
                            .controlSize(.small)
                        }

                        if let error = importError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Runner Labels") {
                        TextField("Labels (comma-separated)", text: $labels)
                            .help("e.g. self-hosted, macOS, ARM64")
                    }

                    Section("Runner Image Profile") {
                        Toggle("Advertise Apple build capabilities", isOn: $imageProfileEnabled)

                        if imageProfileEnabled {
                            TextField("Profile name", text: $imageProfileName)
                            TextField("Base macOS version", text: $baseMacOSVersion)
                                .help("The macOS version installed in the base image")
                            TextField("Xcode version", text: $xcodeVersion)
                            TextField("Developer directory", text: $developerDirectory)
                                .help("Usually /Applications/Xcode.app/Contents/Developer")
                            Toggle("Command-line tools installed", isOn: $commandLineToolsInstalled)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Capabilities")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 8)
                                {
                                    ForEach(AppleBuildCapability.allCases) { capability in
                                        Toggle(
                                            capability.displayName,
                                            isOn: Binding(
                                                get: { selectedCapabilities.contains(capability) },
                                                set: { enabled in
                                                    if enabled {
                                                        selectedCapabilities.insert(capability)
                                                    } else {
                                                        selectedCapabilities.remove(capability)
                                                    }
                                                }
                                            )
                                        )
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }

                            TextField("SDKs", text: $sdkList)
                                .help("Use platform=version entries, e.g. macos=15.0, ios=18.0")
                            TextField("Simulator runtimes", text: $simulatorRuntimeList)
                                .help("Use platform=version entries, e.g. ios=18.0, watchos=11.0")

                            if selectedCapabilities.contains(.macOSDistribution) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Divider()
                                    Text("macOS Distribution")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Packaging and notarization tools")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        LazyVGrid(
                                            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                                            spacing: 8
                                        ) {
                                            Toggle("notarytool", isOn: $distributionNotarytoolInstalled)
                                            Toggle("productbuild", isOn: $distributionProductbuildInstalled)
                                            Toggle("pkgbuild", isOn: $distributionPkgbuildInstalled)
                                            Toggle("hdiutil", isOn: $distributionHdiutilInstalled)
                                            Toggle("stapler", isOn: $distributionStaplerInstalled)
                                        }
                                        .toggleStyle(.checkbox)
                                    }

                                    TextField(
                                        "Developer ID Application identity",
                                        text: $distributionDeveloperIDApplicationIdentity
                                    )
                                    TextField(
                                        "Developer ID Installer identity",
                                        text: $distributionDeveloperIDInstallerIdentity
                                    )
                                    Picker("Notarization credential source", selection: $distributionCredentialSource) {
                                        ForEach(AppleNotarizationCredentialSource.allCases) { source in
                                            Text(source.displayName).tag(source)
                                        }
                                    }
                                    Toggle(
                                        "Notarization credentials supplied outside the base image",
                                        isOn: $distributionCredentialsConfigured
                                    )
                                }
                            }

                            let previewProfile = currentImageProfile
                            if !previewProfile.readinessIssues.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(previewProfile.readinessIssues, id: \.message) { issue in
                                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            } else if !previewProfile.advertisedLabels.isEmpty {
                                Label(
                                    "Adds \(previewProfile.advertisedLabels.joined(separator: ", ")) labels",
                                    systemImage: "tag"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Repository Filter") {
                        Picker("Filter mode", selection: $filterMode) {
                            ForEach(RepositoryFilterMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }

                        if filterMode != .all {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Repositories (one per line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                TextEditor(text: $repositoryList)
                                    .font(.body.monospaced())
                                    .frame(height: 80)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }

                            Text(
                                filterMode == .include
                                    ? "Only jobs from these repositories will be accepted."
                                    : "Jobs from these repositories will be ignored."
                            )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        if let org = existing {
                            viewModel.removeOrganization(org)
                        }
                        dismiss()
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || appId.isEmpty || installationId.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 580)
        .onAppear {
            if let org = existing {
                name = org.name
                appId = org.appId
                installationId = "\(org.installationId)"
                scaleSetId = org.scaleSetId.map(String.init) ?? ""
                labels = org.labels.joined(separator: ", ")
                if let profile = org.imageProfile {
                    imageProfileEnabled = true
                    imageProfileName = profile.name
                    baseMacOSVersion = profile.baseMacOSVersion
                    xcodeVersion = profile.xcodeVersion
                    developerDirectory = profile.developerDirectory
                    commandLineToolsInstalled = profile.commandLineToolsInstalled
                    selectedCapabilities = Set(profile.capabilities)
                    sdkList = formatSDKs(profile.sdks)
                    simulatorRuntimeList = formatSimulatorRuntimes(profile.simulatorRuntimes)
                    distributionNotarytoolInstalled = profile.distribution.notarytoolInstalled
                    distributionProductbuildInstalled = profile.distribution.productbuildInstalled
                    distributionPkgbuildInstalled = profile.distribution.pkgbuildInstalled
                    distributionHdiutilInstalled = profile.distribution.hdiutilInstalled
                    distributionStaplerInstalled = profile.distribution.staplerInstalled
                    distributionDeveloperIDApplicationIdentity = profile.distribution.developerIDApplicationIdentity
                    distributionDeveloperIDInstallerIdentity = profile.distribution.developerIDInstallerIdentity
                    distributionCredentialSource = profile.distribution.notarizationCredentialSource
                    distributionCredentialsConfigured = profile.distribution.notarizationCredentialsConfigured
                }
                filterMode = org.filterMode
                repositoryList = org.filteredRepositories.joined(separator: "\n")
                hasKey = viewModel.hasPrivateKey(for: org)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.init(filenameExtension: "pem") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // When editing, import directly to existing org
            if let org = existing {
                do {
                    try viewModel.importPrivateKey(from: url, for: org)
                    hasKey = true
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            } else {
                // For new org, we'll save after the org is created
                // Store the key data temporarily
                do {
                    guard url.startAccessingSecurityScopedResource() else {
                        importError = "Could not access the selected file"
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    pendingKeyData = try Data(contentsOf: url)
                    hasKey = true
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    @State private var pendingKeyData: Data?

    private func save() {
        let parsedLabels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let parsedInstallationId = Int(installationId) else { return }
        let parsedScaleSetId = Int(scaleSetId)
        let parsedImageProfile = imageProfileEnabled ? currentImageProfile : nil
        let parsedRepos =
            repositoryList
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if var org = existing {
            org.name = name
            org.appId = appId
            org.installationId = parsedInstallationId
            org.scaleSetId = parsedScaleSetId
            org.labels = parsedLabels
            org.imageProfile = parsedImageProfile
            org.filterMode = filterMode
            org.filteredRepositories = parsedRepos
            viewModel.updateOrganization(org)
        } else {
            var org = Organization(
                name: name,
                appId: appId,
                installationId: parsedInstallationId,
                labels: parsedLabels
            )
            org.scaleSetId = parsedScaleSetId
            org.imageProfile = parsedImageProfile
            org.filterMode = filterMode
            org.filteredRepositories = parsedRepos
            viewModel.addOrganization(org)

            // Save pending key data for new org
            if let keyData = pendingKeyData {
                _ = viewModel.configStore.savePrivateKey(keyData, for: org)
            }
        }
        dismiss()
    }

    private var currentImageProfile: RunnerImageProfile {
        RunnerImageProfile(
            name: imageProfileName,
            baseMacOSVersion: baseMacOSVersion,
            xcodeVersion: xcodeVersion,
            developerDirectory: developerDirectory,
            commandLineToolsInstalled: commandLineToolsInstalled,
            sdks: parsePlatformVersions(sdkList).map {
                ApplePlatformSDK(platform: $0.platform, version: $0.version)
            },
            simulatorRuntimes: parsePlatformVersions(simulatorRuntimeList).map {
                AppleSimulatorRuntime(platform: $0.platform, version: $0.version)
            },
            capabilities: AppleBuildCapability.allCases.filter { selectedCapabilities.contains($0) },
            distribution: AppleDistributionToolchain(
                notarytoolInstalled: distributionNotarytoolInstalled,
                productbuildInstalled: distributionProductbuildInstalled,
                pkgbuildInstalled: distributionPkgbuildInstalled,
                hdiutilInstalled: distributionHdiutilInstalled,
                staplerInstalled: distributionStaplerInstalled,
                developerIDApplicationIdentity: distributionDeveloperIDApplicationIdentity,
                developerIDInstallerIdentity: distributionDeveloperIDInstallerIdentity,
                notarizationCredentialSource: distributionCredentialSource,
                notarizationCredentialsConfigured: distributionCredentialsConfigured
            )
        )
    }

    private func parsePlatformVersions(_ text: String) -> [(platform: ApplePlatform, version: String)] {
        text
            .split { $0 == "," || $0 == "\n" }
            .compactMap { rawEntry in
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty else { return nil }

                let parts = entry.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2,
                    let platform = ApplePlatform(rawValue: parts[0].lowercased()),
                    !parts[1].isEmpty
                else {
                    return nil
                }
                return (platform, parts[1])
            }
    }

    private func formatSDKs(_ sdks: [ApplePlatformSDK]) -> String {
        sdks.map { "\($0.platform.rawValue)=\($0.version)" }.joined(separator: ", ")
    }

    private func formatSimulatorRuntimes(_ runtimes: [AppleSimulatorRuntime]) -> String {
        runtimes
            .filter(\.isAvailable)
            .map { "\($0.platform.rawValue)=\($0.version)" }
            .joined(separator: ", ")
    }
}
