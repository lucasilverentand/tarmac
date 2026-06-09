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
        #expect(vm.activeVMRole == nil)
        #expect(!vm.hasDisplayableVM)
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
        vm.activeVMRole = .jobRunner
        #expect(vm.activeVM?.jobId == 42)
        #expect(vm.activeVM?.state == .running)
        #expect(vm.activeVMRole == .jobRunner)
        #expect(vm.hasDisplayableVM)
    }

    @Test("Warm runner role carries display metadata")
    @MainActor
    func warmRunnerRoleMetadata() {
        let vm = VMStatusViewModel()
        vm.activeVMRole = .warmRunnerIdle
        vm.warmRunnerJobsServed = 3
        vm.warmRunnerLastActivityAt = Date(timeIntervalSince1970: 100)

        #expect(vm.activeVMRole?.displayTitle == "Warm runner idle")
        #expect(vm.activeVMRole?.statusText == "Warm runner waiting for reuse")
        #expect(vm.activeVMRole?.isWarmRunner == true)
        #expect(vm.warmRunnerJobsServed == 3)
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
