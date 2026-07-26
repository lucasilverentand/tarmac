import Virtualization

enum VMInputDeviceConfigurator {
    static func attachInteractiveDevices(to configuration: VZVirtualMachineConfiguration) {
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }
}
