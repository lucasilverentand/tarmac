import Foundation

@Observable
@MainActor
final class VMStatusViewModel {
    var activeVM: VMInstance?
    var baseImageExists: Bool = false
    var installProgress: Double = 0
    var isInstalling: Bool = false
}
