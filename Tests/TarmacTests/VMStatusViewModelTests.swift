import Foundation
import Testing

@testable import Tarmac

@Suite("VMStatusViewModel")
struct VMStatusViewModelTests {
    @Test("Initial state has nil activeVM")
    @MainActor
    func initialActiveVM() {
        let vm = VMStatusViewModel()
        #expect(vm.activeVM == nil)
    }

    @Test("Initial state has baseImageExists false")
    @MainActor
    func initialBaseImageExists() {
        let vm = VMStatusViewModel()
        #expect(vm.baseImageExists == false)
    }

    @Test("Initial state has zero installProgress")
    @MainActor
    func initialInstallProgress() {
        let vm = VMStatusViewModel()
        #expect(vm.installProgress == 0)
    }

    @Test("Initial state has isInstalling false")
    @MainActor
    func initialIsInstalling() {
        let vm = VMStatusViewModel()
        #expect(vm.isInstalling == false)
    }

    @Test("Setting activeVM updates property")
    @MainActor
    func setActiveVM() {
        let vm = VMStatusViewModel()
        let instance = VMInstance(
            id: UUID(),
            jobId: 42,
            diskImagePath: URL(filePath: "/tmp/disk.img"),
            startedAt: Date(),
            state: .running
        )
        vm.activeVM = instance
        #expect(vm.activeVM?.jobId == 42)
        #expect(vm.activeVM?.state == .running)
    }

    @Test("Setting baseImageExists updates property")
    @MainActor
    func setBaseImageExists() {
        let vm = VMStatusViewModel()
        vm.baseImageExists = true
        #expect(vm.baseImageExists == true)
    }

    @Test("Setting installProgress updates property")
    @MainActor
    func setInstallProgress() {
        let vm = VMStatusViewModel()
        vm.installProgress = 0.75
        #expect(vm.installProgress == 0.75)
    }

    @Test("Setting isInstalling updates property")
    @MainActor
    func setIsInstalling() {
        let vm = VMStatusViewModel()
        vm.isInstalling = true
        #expect(vm.isInstalling == true)
    }
}
