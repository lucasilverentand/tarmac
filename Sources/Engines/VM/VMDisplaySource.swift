import Foundation
import Virtualization

enum VMDisplayInteractionMode: String, Sendable {
    case observe
    case takeOver
}

@Observable
@MainActor
final class VMDisplaySource {
    static let shared = VMDisplaySource()

    private(set) var activeVM: VZVirtualMachine?
    private(set) var label: String = ""
    private(set) var detail: String = ""
    var interactionMode: VMDisplayInteractionMode = .observe

    var hasActiveDisplay: Bool {
        activeVM != nil
    }

    func publish(vm: VZVirtualMachine, label: String, detail: String = "") {
        if activeVM !== vm {
            interactionMode = .observe
        }
        self.activeVM = vm
        self.label = label
        self.detail = detail
    }

    func updateMetadata(label: String, detail: String = "") {
        self.label = label
        self.detail = detail
    }

    func observe() {
        interactionMode = .observe
    }

    func takeOver() {
        interactionMode = .takeOver
    }

    func clear() {
        self.activeVM = nil
        self.label = ""
        self.detail = ""
        self.interactionMode = .observe
    }
}
