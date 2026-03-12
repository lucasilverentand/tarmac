import SwiftUI

struct VMStatusCard: View {
    let vmStatusViewModel: VMStatusViewModel
    let vmConfig: VMConfiguration
    let configStore: ConfigStore

    @State private var showingImageWizard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Virtual Machine")
                .font(.headline)

            Divider()

            baseImageSection
            Divider()
            activeVMSection
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingImageWizard) {
            BaseImageWizardView(configStore: configStore)
        }
    }

    @ViewBuilder
    private var baseImageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Base Image")
                .font(.subheadline.weight(.medium))

            if vmStatusViewModel.baseImageExists {
                Label("Base image ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Label("Base image missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)

                Button("Set up base image...") {
                    showingImageWizard = true
                }
                .controlSize(.small)
            }

            if vmStatusViewModel.isInstalling {
                ProgressView(value: vmStatusViewModel.installProgress)
                    .progressViewStyle(.linear)
                Text("\(Int(vmStatusViewModel.installProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var activeVMSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.subheadline.weight(.medium))

            if let vm = vmStatusViewModel.activeVM {
                Label("VM running", systemImage: "play.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

                LabeledContent("Job ID", value: "\(vm.jobId)")
                    .font(.caption)
                LabeledContent("Boot time", value: vm.startedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                LabeledContent("CPU", value: "\(vmConfig.cpuCount) cores")
                    .font(.caption)
                LabeledContent("Memory", value: "\(vmConfig.memorySizeGB) GB")
                    .font(.caption)
            } else {
                Label("No VM running", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }
}
