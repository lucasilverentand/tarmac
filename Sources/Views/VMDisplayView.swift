import SwiftUI
import Virtualization

struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== virtualMachine {
            nsView.virtualMachine = virtualMachine
        }
    }
}

struct VMDisplayWindow: View {
    @State private var source = VMDisplaySource.shared

    var body: some View {
        Group {
            if let vm = source.activeVM {
                VMDisplayView(virtualMachine: vm)
                    .navigationTitle(source.label.isEmpty ? "VM Display" : source.label)
            } else {
                ContentUnavailableView(
                    "No VM Running",
                    systemImage: "desktopcomputer",
                    description: Text("Start a job or run base image verification to see the VM here.")
                )
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
