import Foundation
import Virtualization

@Observable
@MainActor
final class VMDisplaySource {
    static let shared = VMDisplaySource()

    private(set) var activeVM: VZVirtualMachine?
    private(set) var label: String = ""

    func publish(vm: VZVirtualMachine, label: String) {
        self.activeVM = vm
        self.label = label
    }

    func clear() {
        self.activeVM = nil
        self.label = ""
    }
}
