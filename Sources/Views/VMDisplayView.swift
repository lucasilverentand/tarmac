import AppKit
import SwiftUI
import Virtualization

struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?
    let isInteractive: Bool

    final class Coordinator {
        var wasInteractive = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = isInteractive
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        view.setAccessibilityLabel("Virtual machine display")
        context.coordinator.wasInteractive = isInteractive
        if isInteractive {
            focus(view)
        }
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        let virtualMachineChanged = nsView.virtualMachine !== virtualMachine
        if virtualMachineChanged {
            nsView.virtualMachine = virtualMachine
        }
        nsView.capturesSystemKeys = isInteractive

        let becameInteractive = isInteractive && !context.coordinator.wasInteractive
        context.coordinator.wasInteractive = isInteractive

        if becameInteractive || (isInteractive && virtualMachineChanged) {
            focus(nsView)
        } else if !isInteractive, nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    private func focus(_ view: VZVirtualMachineView) {
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }
}

struct VMDisplayWindow: View {
    @State private var source = VMDisplaySource.shared

    var body: some View {
        Group {
            if let vm = source.activeVM {
                VStack(spacing: 0) {
                    header

                    ZStack {
                        VMDisplayView(
                            virtualMachine: vm,
                            isInteractive: source.interactionMode == .takeOver
                        )

                        if source.interactionMode == .observe {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                    }
                }
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
        .onDisappear {
            source.observe()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label.isEmpty ? "VM Display" : source.label)
                    .font(.headline)
                if !source.detail.isEmpty {
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("Mode", selection: $source.interactionMode) {
                Label("Observe", systemImage: "eye").tag(VMDisplayInteractionMode.observe)
                Label("Take Over", systemImage: "keyboard").tag(VMDisplayInteractionMode.takeOver)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
