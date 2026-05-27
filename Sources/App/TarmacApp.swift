import AppKit
import SwiftUI

@main
struct TarmacApp: App {
    @NSApplicationDelegateAdaptor(TarmacAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .onAppear {
                    Log.app.info("Menu bar popover appeared")
                    if !appState.configStore.hasCompletedStorageSetup || appState.configStore.organizations.isEmpty {
                        Log.app.info("Setup incomplete — opening dashboard for onboarding")
                        openWindow(id: "dashboard")
                    }
                }
        } label: {
            MenuBarIcon(
                queueViewModel: appState.queueViewModel,
                vmStatusViewModel: appState.vmStatusViewModel
            )
            .task {
                appDelegate.appState = appState
                await appState.start()
                appState.syncVMControlServer()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: "dashboard") {
            DashboardView(appState: appState)
                .onAppear {
                    Log.app.info("Dashboard window opened")
                    NSApp.activate()
                    centerDashboard()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.selectedSection = .storage
                    openWindow(id: "dashboard")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("VM Display", id: "vm-display") {
            VMDisplayWindow()
        }
        .windowResizability(.contentMinSize)
    }

}

@MainActor
final class TarmacAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        guard let appState else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await appState.shutdownForTermination()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
    }
}

extension TarmacApp {
    private func centerDashboard() {
        DispatchQueue.main.async {
            guard
                let window = NSApp.windows.first(where: {
                    ($0.isVisible && $0.identifier?.rawValue.contains("dashboard") == true)
                        || ($0.title == "Dashboard" && $0.level == .normal)
                })
            else { return }
            window.level = .normal
            window.center()
        }
    }
}
