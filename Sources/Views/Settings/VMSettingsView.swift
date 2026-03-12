import SwiftUI

struct VMSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    private var maxCPU: Int { ProcessInfo.processInfo.processorCount }
    private var maxMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) }

    var body: some View {
        Form {
            Section("Resources") {
                Stepper(
                    "CPU cores: \(viewModel.vmConfiguration.cpuCount)",
                    value: $viewModel.vmConfiguration.cpuCount,
                    in: 1...maxCPU
                )

                Stepper(
                    "Memory: \(viewModel.vmConfiguration.memorySizeGB) GB",
                    value: $viewModel.vmConfiguration.memorySizeGB,
                    in: 4...maxMemoryGB
                )

                Stepper(
                    "Disk size: \(viewModel.vmConfiguration.diskSizeGB) GB",
                    value: $viewModel.vmConfiguration.diskSizeGB,
                    in: 40...500,
                    step: 10
                )
            }

            Section("Current Configuration") {
                LabeledContent("CPU", value: "\(viewModel.vmConfiguration.cpuCount) cores")
                LabeledContent("Memory", value: "\(viewModel.vmConfiguration.memorySizeGB) GB")
                LabeledContent("Disk", value: "\(viewModel.vmConfiguration.diskSizeGB) GB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
