import Testing
import Virtualization

@testable import Tarmac

@Suite("VM input device configuration")
struct VMInputDeviceConfiguratorTests {
    @Test("interactive VMs attach a keyboard and absolute pointing device")
    func attachesInteractiveInputDevices() {
        let configuration = VZVirtualMachineConfiguration()

        VMInputDeviceConfigurator.attachInteractiveDevices(to: configuration)

        #expect(configuration.keyboards.count == 1)
        #expect(configuration.keyboards.first is VZUSBKeyboardConfiguration)
        #expect(configuration.pointingDevices.count == 1)
        #expect(configuration.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
    }
}
