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
                    Text("Drag to set priority — top account is dispatched first")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Add Account...") {
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
        VStack(spacing: 18) {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "building.2",
                description: Text("Add a GitHub organization or enterprise to start receiving runner jobs.")
            )

            GitHubSetupGuidanceList(items: GitHubSetupGuidance.setupOverview)
                .padding(.horizontal, 32)
                .frame(maxWidth: 640)
        }
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

                    Text(org.accountType.displayName.lowercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())

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

// MARK: - Setup Guidance

private struct GitHubSetupGuidanceList: View {
    let items: [GitHubSetupGuidance]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                GuidanceCallout(item: item)
            }
        }
    }
}

private struct GuidanceCallout: View {
    let item: GitHubSetupGuidance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }

    private var iconName: String {
        switch item.scope {
        case .organization:
            "building.2"
        case .repository:
            "line.3.horizontal.decrease.circle"
        case .enterprise:
            "exclamationmark.triangle"
        case .permissions:
            "key"
        }
    }

    private var iconColor: Color {
        switch item.scope {
        case .enterprise:
            .orange
        default:
            .secondary
        }
    }
}

// MARK: - Form Sheet

private struct OrganizationFormSheet: View {
    let viewModel: SettingsViewModel
    var existing: Organization?

    @State private var name: String = ""
    @State private var accountType: GitHubAccountType = .organization
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
    @State private var baseImageIdentifier = ""
    @State private var preparationSteps = BaseImagePreparationStep.defaultSteps
    @State private var commandLineToolsVersion = ""
    @State private var xcodeLicenseAccepted = false
    @State private var flutterVersion = ""
    @State private var dartVersion = ""
    @State private var nodeVersion = ""
    @State private var packageManagerList = ""
    @State private var rubyVersion = ""
    @State private var cocoaPodsVersion = ""
    @State private var expoCLIVersion = ""
    @State private var easCLIVersion = ""
    @State private var selectedCapabilities: Set<AppleBuildCapability> = []
    @State private var sdkList = ""
    @State private var simulatorRuntimeList = ""
    @State private var filterMode: RepositoryFilterMode = .all
    @State private var repositoryList: String = ""
    @State private var hasKey: Bool = false
    @State private var showingFileImporter = false
    @State private var importError: String?

    @Environment(\.dismiss) private var dismiss

    var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Account" : "Add Account")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ScrollView {
                Form {
                    Section("Account") {
                        GitHubSetupGuidanceList(items: [
                            .organization,
                            .enterprise,
                        ])

                        Picker("Type", selection: $accountType) {
                            ForEach(GitHubAccountType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isEditing)

                        TextField(accountType == .enterprise ? "Enterprise slug" : "Organization name", text: $name)
                            .disabled(isEditing)
                            .help(
                                accountType == .enterprise
                                    ? "The enterprise slug as shown in github.com/enterprises/<slug>"
                                    : "The organization login as shown in github.com/<name>"
                            )
                        TextField("Installation ID", text: $installationId)
                            .help("The GitHub App installation ID for this account")
                        TextField("Scale Set ID", text: $scaleSetId)
                            .help("The numeric ID of your Actions Runner Scale Set for this account")
                    }

                    Section("GitHub App Credentials") {
                        GuidanceCallout(item: .permissions)

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

                            preparationSection

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
                        GuidanceCallout(item: .repository)

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
                accountType = org.accountType
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
                    let preparation = profile.preparation ?? BaseImagePreparation()
                    baseImageIdentifier = preparation.baseImageIdentifier
                    preparationSteps = preparation.steps
                    commandLineToolsVersion = preparation.inventory.commandLineToolsVersion
                    xcodeLicenseAccepted = preparation.inventory.xcodeLicenseAccepted
                    flutterVersion = preparation.inventory.flutterVersion
                    dartVersion = preparation.inventory.dartVersion
                    nodeVersion = preparation.inventory.nodeVersion
                    packageManagerList = formatPackageManagers(preparation.inventory.packageManagers)
                    rubyVersion = preparation.inventory.rubyVersion
                    cocoaPodsVersion = preparation.inventory.cocoaPodsVersion
                    expoCLIVersion = preparation.inventory.expoCLIVersion
                    easCLIVersion = preparation.inventory.easCLIVersion
                    selectedCapabilities = Set(profile.capabilities)
                    sdkList = formatSDKs(profile.sdks)
                    simulatorRuntimeList = formatSimulatorRuntimes(profile.simulatorRuntimes)
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
            org.accountType = accountType
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
                accountType: accountType,
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
            preparation: currentPreparation
        )
    }

    private var currentPreparation: BaseImagePreparation {
        BaseImagePreparation(
            baseImageIdentifier: baseImageIdentifier,
            steps: preparationSteps,
            inventory: ToolchainInventory(
                capturedAt: Date(),
                commandLineToolsVersion: commandLineToolsVersion,
                xcodeLicenseAccepted: xcodeLicenseAccepted,
                flutterVersion: flutterVersion,
                dartVersion: dartVersion,
                nodeVersion: nodeVersion,
                packageManagers: parsePackageManagers(packageManagerList),
                rubyVersion: rubyVersion,
                cocoaPodsVersion: cocoaPodsVersion,
                expoCLIVersion: expoCLIVersion,
                easCLIVersion: easCLIVersion
            ),
            updatedAt: Date()
        )
    }

    @ViewBuilder
    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Base image preparation")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Base image identifier", text: $baseImageIdentifier)
                .help("Use a stable image build, disk, or snapshot identifier so stale inventory is visible.")
            TextField("Command-line tools version", text: $commandLineToolsVersion)
            Toggle("Xcode license accepted", isOn: $xcodeLicenseAccepted)

            ForEach(preparationSteps.indices, id: \.self) { index in
                HStack {
                    Text(preparationSteps[index].id.displayName)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { preparationSteps[index].status },
                            set: { status in
                                preparationSteps[index].status = status
                                preparationSteps[index].updatedAt = Date()
                            }
                        )
                    ) {
                        ForEach(PreparationStepStatus.allCases) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            DisclosureGroup("Optional tool inventory") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Flutter version", text: $flutterVersion)
                    TextField("Dart version", text: $dartVersion)
                    TextField("Node version", text: $nodeVersion)
                    TextField("Package managers", text: $packageManagerList)
                        .help("Use manager=version entries, e.g. npm=10.8, yarn=1.22")
                    TextField("Ruby version", text: $rubyVersion)
                    TextField("CocoaPods version", text: $cocoaPodsVersion)
                    TextField("Expo CLI version", text: $expoCLIVersion)
                    TextField("EAS CLI version", text: $easCLIVersion)
                }
                .padding(.top, 6)
            }
        }
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

    private func parsePackageManagers(_ text: String) -> [PackageManagerInventory] {
        text
            .split { $0 == "," || $0 == "\n" }
            .compactMap { rawEntry in
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty else { return nil }
                let parts = entry.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2,
                    let manager = JavaScriptPackageManager(rawValue: parts[0].lowercased()),
                    !parts[1].isEmpty
                else {
                    return nil
                }
                return PackageManagerInventory(manager: manager, version: parts[1])
            }
    }

    private func formatPackageManagers(_ packageManagers: [PackageManagerInventory]) -> String {
        packageManagers
            .map { "\($0.manager.rawValue)=\($0.version)" }
            .joined(separator: ", ")
    }
}
