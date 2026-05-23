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

                Divider()
                footer
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            OrganizationFormSheet(viewModel: viewModel)
        }
        .sheet(item: $editingOrg) { org in
            OrganizationFormSheet(viewModel: viewModel, existing: org)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "building.2")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 8) {
                    Text("No Accounts")
                        .font(.title2.weight(.semibold))

                    Text("Add a GitHub organization to start receiving runner jobs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }

                GitHubSetupGuidanceList(items: GitHubSetupGuidance.setupOverview)
                    .frame(maxWidth: 640)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Drag to set priority — top account is dispatched first")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Add Account...") {
                showingAddSheet = true
            }
            .controlSize(.small)
        }
        .padding(12)
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

private struct GitHubAppSetupGuideView: View {
    let accountType: GitHubAccountType
    let accountName: String

    @State private var showingGitHubFields = true
    @State private var showingTarmacFields = true
    @State private var showingSteps = false
    @Environment(\.openURL) private var openURL

    private var guide: GitHubAppSetupGuide {
        GitHubAppSetupGuide.guide(for: accountType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(guide.title, systemImage: accountType == .enterprise ? "building.columns" : "building.2")
                    .font(.caption.weight(.semibold))

                Spacer()

                Button {
                    if let url = guide.registrationURL(accountName: accountName) {
                        openURL(url)
                    }
                } label: {
                    Label("Open in GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .disabled(guide.registrationURL(accountName: accountName) == nil)

                if let docsURL = URL(string: guide.documentationURL) {
                    Link(destination: docsURL) {
                        Label("Docs", systemImage: "book")
                    }
                    .controlSize(.small)
                }
            }

            Text(guide.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub setup URL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(guide.registrationPath(accountName: accountName))
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .tertiary : .secondary
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(
                        accountType == .enterprise
                            ? "Enter the enterprise slug to enable the setup link."
                            : "Enter the organization name to enable the setup link."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Divider()

            DisclosureGroup("GitHub fields to fill", isExpanded: $showingGitHubFields) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(guide.resolvedAppFields(accountName: accountName)) { field in
                        GuideFieldRow(label: field.field, value: field.value, detail: field.detail)
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Values to copy into Tarmac", isExpanded: $showingTarmacFields) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(guide.tarmacFields) { field in
                        GuideFieldRow(label: field.field, value: nil, detail: field.detail)
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("After creating the app", isExpanded: $showingSteps) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(guide.afterCreationSteps) { step in
                        GuideStepRow(step: step)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GuideFieldRow: View {
    let label: String
    let value: String?
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 142, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GuideStepRow: View {
    let step: GitHubAppSetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(step.number)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption.weight(.semibold))

                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FieldInlineHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OrganizationFormSheet: View {
    let viewModel: SettingsViewModel
    var existing: Organization?

    @State private var name: String = ""
    @State private var accountType: GitHubAccountType = .organization
    @State private var appOwnerType: GitHubAccountType = .organization
    @State private var enterpriseSlug: String = ""
    @State private var appId: String = ""
    @State private var installationId: String = ""
    @State private var scaleSetId: String = ""
    @State private var labels: String = "self-hosted, macOS, ARM64"
    @State private var imageProfileEnabled = false
    @State private var imageProfileName = "Apple Platform"
    @State private var runnerBaseImagePath = ""
    @State private var overrideVMConfiguration = false
    @State private var runnerCPUCount = "4"
    @State private var runnerMemorySizeGB = "8"
    @State private var runnerDiskSizeGB = "80"
    @State private var runnerCompletionTimeoutSeconds = "3600"
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
    @State private var hasPrivateKey: Bool = false
    @State private var hasAccessToken: Bool = false
    @State private var accessToken: String = ""
    @State private var showingFileImporter = false
    @State private var importError: String?
    @State private var installationLookupInFlight = false
    @State private var installationLookupError: String?
    @State private var imageScanInFlight = false
    @State private var imageScanError: String?

    @Environment(\.dismiss) private var dismiss

    var isEditing: Bool { existing != nil }

    private var setupGuide: GitHubAppSetupGuide {
        GitHubAppSetupGuide.guide(for: appOwnerType)
    }

    private var setupGuideAccountName: String {
        switch appOwnerType {
        case .organization:
            name
        case .enterprise:
            enterpriseSlug
        }
    }

    private var availableAccountTypes: [GitHubAccountType] {
        GitHubAccountType.runnerAccountTypes
    }

    private var canSave: Bool {
        let hasAccountName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch accountType {
        case .organization:
            return hasAccountName
                && !appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Int(installationId) != nil
        case .enterprise:
            return hasAccountName
                && (hasAccessToken || !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var locksAccountIdentity: Bool {
        isEditing && existing?.accountType != .enterprise
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Account" : "Add Account")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ScrollView {
                Form {
                    Section("Account") {
                        if !locksAccountIdentity {
                            Picker("Runner account", selection: $accountType) {
                                ForEach(availableAccountTypes) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(locksAccountIdentity)

                            if accountType == .enterprise {
                                GuidanceCallout(item: .enterprise)
                            }
                        }

                        TextField(accountType == .enterprise ? "Enterprise slug" : "Organization name", text: $name)
                            .disabled(locksAccountIdentity)
                            .help(
                                accountType == .enterprise
                                    ? "The enterprise slug as shown in github.com/enterprises/<slug>"
                                    : "The organization login as shown in github.com/<name>"
                            )
                        FieldInlineHint(text: tarmacFieldDetail(.accountName))

                        if accountType == .organization {
                            HStack {
                                TextField("Installation ID", text: $installationId)
                                    .help("The GitHub App installation ID for this organization")

                                Button {
                                    findInstallation()
                                } label: {
                                    if installationLookupInFlight {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("Find Installation", systemImage: "magnifyingglass")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(installationLookupInFlight)
                            }
                            FieldInlineHint(text: tarmacFieldDetail(.installationId))
                            if let installationLookupError {
                                Text(installationLookupError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        TextField("Scale Set ID", text: $scaleSetId)
                            .help("The numeric ID of your Actions Runner Scale Set for this account")
                        FieldInlineHint(text: tarmacFieldDetail(.scaleSetId))
                    }

                    if accountType == .organization {
                        Section("GitHub App Credentials") {
                            Picker("App owner", selection: $appOwnerType) {
                                Text("Organization").tag(GitHubAccountType.organization)
                                Text("Enterprise").tag(GitHubAccountType.enterprise)
                            }
                            .pickerStyle(.segmented)

                            if appOwnerType == .enterprise {
                                TextField("Enterprise slug", text: $enterpriseSlug)
                                    .help("The enterprise slug as shown in github.com/enterprises/<slug>")
                                FieldInlineHint(
                                    text:
                                        "Use this when the GitHub App is created from Enterprise settings. The runner account above still stays as the organization; do not paste an enterprise installation ID."
                                )
                            }

                            GitHubAppSetupGuideView(accountType: appOwnerType, accountName: setupGuideAccountName)

                            TextField("App ID", text: $appId)
                            FieldInlineHint(text: tarmacFieldDetail(.appId))

                            HStack {
                                if hasPrivateKey {
                                    Label("Private key imported", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.subheadline)
                                } else {
                                    Label("No key imported", systemImage: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }

                                Spacer()

                                if hasPrivateKey {
                                    Button("Remove", role: .destructive) {
                                        if let org = existing {
                                            viewModel.deletePrivateKey(for: org)
                                        } else {
                                            pendingKeyData = nil
                                        }
                                        hasPrivateKey = false
                                        installationLookupError = nil
                                    }
                                    .controlSize(.small)
                                }

                                Button("Import .pem file...") {
                                    showingFileImporter = true
                                }
                                .controlSize(.small)
                            }

                            FieldInlineHint(text: tarmacFieldDetail(.privateKey))

                            if let error = importError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        Section("Enterprise Access") {
                            FieldInlineHint(
                                text:
                                    "Enterprise runner APIs require a classic PAT or OAuth token with manage_runners:enterprise. GitHub App installation tokens cannot manage enterprise runners."
                            )

                            if hasAccessToken {
                                Label("Access token saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.subheadline)
                            } else {
                                Label("No access token saved", systemImage: "xmark.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }

                            SecureField(hasAccessToken ? "Replace access token" : "Access token", text: $accessToken)
                                .textContentType(.password)

                            if hasAccessToken {
                                Button("Remove saved token", role: .destructive) {
                                    if let org = existing {
                                        _ = viewModel.deleteAccessToken(for: org)
                                    }
                                    accessToken = ""
                                    hasAccessToken = false
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    Section("Runner Labels") {
                        TextField("Labels (comma-separated)", text: $labels)
                            .help("e.g. self-hosted, macOS, ARM64")
                        FieldInlineHint(text: tarmacFieldDetail(.labels))
                    }

                    Section("Runner Image Profile") {
                        Toggle("Advertise Apple build capabilities", isOn: $imageProfileEnabled)

                        if imageProfileEnabled {
                            TextField("Profile name", text: $imageProfileName)
                            TextField("Runner image path", text: $runnerBaseImagePath)
                                .help("Leave blank to use the managed base image.")

                            HStack {
                                Button("Use Managed Image") {
                                    runnerBaseImagePath = viewModel.baseImagePath
                                }
                                .controlSize(.small)

                                Button {
                                    scanRunnerImage()
                                } label: {
                                    if imageScanInFlight {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("Scan Image", systemImage: "waveform.path.ecg")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(imageScanInFlight)
                            }

                            Text(
                                "Scanning boots a temporary clone of this image, records the installed Apple toolchain, and updates the advertised labels from what is actually present."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if let imageScanError {
                                Text(imageScanError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Toggle("Override VM resources for this runner image", isOn: $overrideVMConfiguration)

                            if overrideVMConfiguration {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                    GridRow {
                                        TextField("CPU", text: $runnerCPUCount)
                                        TextField("Memory GB", text: $runnerMemorySizeGB)
                                    }
                                    GridRow {
                                        TextField("Disk GB", text: $runnerDiskSizeGB)
                                        TextField("Timeout seconds", text: $runnerCompletionTimeoutSeconds)
                                    }
                                }
                            }

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
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 720, height: 780)
        .onAppear {
            if let org = existing {
                name = org.name
                accountType = org.accountType
                appOwnerType = org.accountType == .enterprise ? .enterprise : .organization
                enterpriseSlug = org.accountType == .enterprise ? org.name : ""
                appId = org.appId
                installationId = "\(org.installationId)"
                scaleSetId = org.scaleSetId.map(String.init) ?? ""
                labels = org.labels.joined(separator: ", ")
                if let profile = org.imageProfile {
                    applyImageProfile(profile)
                }
                filterMode = org.filterMode
                repositoryList = org.filteredRepositories.joined(separator: "\n")
                hasPrivateKey = viewModel.hasPrivateKey(for: org)
                hasAccessToken = viewModel.hasAccessToken(for: org)
            } else {
                runnerCPUCount = "\(viewModel.vmConfiguration.cpuCount)"
                runnerMemorySizeGB = "\(viewModel.vmConfiguration.memorySizeGB)"
                runnerDiskSizeGB = "\(viewModel.vmConfiguration.diskSizeGB)"
                runnerCompletionTimeoutSeconds = "\(viewModel.vmConfiguration.runnerCompletionTimeoutSeconds)"
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
                    hasPrivateKey = true
                    importError = nil
                    installationLookupError = nil
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
                    hasPrivateKey = true
                    importError = nil
                    installationLookupError = nil
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    @State private var pendingKeyData: Data?

    private func tarmacFieldDetail(_ kind: TarmacAccountFieldGuide.Kind) -> String {
        if accountType == .enterprise {
            switch kind {
            case .accountName:
                return "Enter the enterprise slug as shown in github.com/enterprises/<slug>."
            case .scaleSetId:
                return "Enter the numeric enterprise runner scale set ID that Tarmac should poll."
            case .labels:
                return "Keep self-hosted and add the labels workflows use in runs-on, such as macOS and ARM64."
            default:
                return ""
            }
        }
        return setupGuide.tarmacFields.first { $0.kind == kind }?.detail ?? ""
    }

    private func findInstallation() {
        installationLookupError = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard accountType == .organization else {
            installationLookupError =
                "Enterprise runner accounts use an access token and do not have an installation ID."
            return
        }
        guard !trimmedName.isEmpty else {
            installationLookupError = "Enter the organization name first."
            return
        }
        guard !trimmedAppId.isEmpty else {
            installationLookupError = "Enter the App ID first."
            return
        }
        guard let keyData = lookupPrivateKeyData else {
            installationLookupError = "Import the GitHub App private key before finding the installation."
            return
        }

        installationLookupInFlight = true
        Task {
            do {
                let id = try await viewModel.findOrganizationInstallationId(
                    organizationName: trimmedName,
                    appId: trimmedAppId,
                    privateKeyData: keyData
                )
                installationId = "\(id)"
                installationLookupError = nil
            } catch {
                installationLookupError =
                    "Could not find an installation for \(trimmedName). Confirm the app is installed on that organization and the App ID/private key match."
            }
            installationLookupInFlight = false
        }
    }

    private var lookupPrivateKeyData: Data? {
        if let pendingKeyData {
            return pendingKeyData
        }
        guard let existing else {
            return nil
        }
        return viewModel.configStore.loadPrivateKey(for: existing)
    }

    private func save() {
        let parsedLabels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let parsedInstallationId: Int
        switch accountType {
        case .organization:
            guard let id = Int(installationId) else { return }
            parsedInstallationId = id
        case .enterprise:
            parsedInstallationId = 0
        }
        let parsedScaleSetId = Int(scaleSetId)
        let parsedImageProfile = imageProfileEnabled ? currentImageProfile : nil
        let parsedRepos =
            repositoryList
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if var org = existing {
            let previousAccountType = org.accountType
            org.name = name
            org.accountType = accountType
            org.appId = accountType == .organization ? appId : ""
            org.installationId = parsedInstallationId
            org.scaleSetId = parsedScaleSetId
            org.labels = parsedLabels
            org.imageProfile = parsedImageProfile
            org.filterMode = filterMode
            org.filteredRepositories = parsedRepos
            viewModel.updateOrganization(org)
            if accountType == .enterprise,
                !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                _ = viewModel.saveAccessToken(accessToken, for: org)
            } else if accountType == .organization && previousAccountType == .enterprise {
                _ = viewModel.deleteAccessToken(for: org)
            }
        } else {
            var org = Organization(
                name: name,
                accountType: accountType,
                appId: accountType == .organization ? appId : "",
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
            if accountType == .enterprise {
                _ = viewModel.saveAccessToken(accessToken, for: org)
            }
        }
        dismiss()
    }

    private var currentImageProfile: RunnerImageProfile {
        RunnerImageProfile(
            name: imageProfileName,
            baseImagePath: effectiveRunnerBaseImagePath,
            vmConfiguration: overrideVMConfiguration ? currentRunnerVMConfiguration : nil,
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

    private var effectiveRunnerBaseImagePath: String {
        let path = runnerBaseImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? viewModel.baseImagePath : path
    }

    private var currentRunnerVMConfiguration: VMConfiguration {
        VMConfiguration(
            cpuCount: parsedPositiveInt(runnerCPUCount, fallback: viewModel.vmConfiguration.cpuCount),
            memorySizeGB: parsedPositiveInt(runnerMemorySizeGB, fallback: viewModel.vmConfiguration.memorySizeGB),
            diskSizeGB: parsedPositiveInt(runnerDiskSizeGB, fallback: viewModel.vmConfiguration.diskSizeGB),
            runnerCompletionTimeoutSeconds: parsedPositiveInt(
                runnerCompletionTimeoutSeconds,
                fallback: viewModel.vmConfiguration.runnerCompletionTimeoutSeconds
            )
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

    private func scanRunnerImage() {
        imageProfileEnabled = true
        imageScanInFlight = true
        imageScanError = nil

        let imagePath = effectiveRunnerBaseImagePath
        let vmConfig = currentRunnerVMConfiguration
        let scanName =
            imageProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Detected Apple Platform"
            : imageProfileName

        Task {
            do {
                let report = try await viewModel.scanRunnerImage(
                    baseImagePath: imagePath,
                    vmConfiguration: vmConfig
                )
                let profile = RunnerImageProfile.automatic(
                    from: report,
                    baseImagePath: imagePath,
                    vmConfiguration: overrideVMConfiguration ? vmConfig : nil,
                    name: scanName
                )
                applyImageProfile(profile)
            } catch {
                imageScanError = error.localizedDescription
            }
            imageScanInFlight = false
        }
    }

    private func applyImageProfile(_ profile: RunnerImageProfile) {
        imageProfileEnabled = true
        imageProfileName = profile.name
        runnerBaseImagePath = profile.baseImagePath
        if let vmConfiguration = profile.vmConfiguration {
            overrideVMConfiguration = true
            runnerCPUCount = "\(vmConfiguration.cpuCount)"
            runnerMemorySizeGB = "\(vmConfiguration.memorySizeGB)"
            runnerDiskSizeGB = "\(vmConfiguration.diskSizeGB)"
            runnerCompletionTimeoutSeconds = "\(vmConfiguration.runnerCompletionTimeoutSeconds)"
        } else {
            overrideVMConfiguration = false
            runnerCPUCount = "\(viewModel.vmConfiguration.cpuCount)"
            runnerMemorySizeGB = "\(viewModel.vmConfiguration.memorySizeGB)"
            runnerDiskSizeGB = "\(viewModel.vmConfiguration.diskSizeGB)"
            runnerCompletionTimeoutSeconds = "\(viewModel.vmConfiguration.runnerCompletionTimeoutSeconds)"
        }
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

    private func parsedPositiveInt(_ text: String, fallback: Int) -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return fallback
        }
        return value
    }
}
