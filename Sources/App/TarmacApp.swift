import AppKit
import SwiftUI

@main
struct TarmacApp: App {
    @State private var appState = AppState()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .onAppear {
                    Log.app.info("Menu bar popover appeared")
                    if appState.configStore.organizations.isEmpty {
                        Log.app.info("No orgs configured — opening dashboard for onboarding")
                        openWindow(id: "dashboard")
                    }
                }
        } label: {
            MenuBarIcon(queueViewModel: appState.queueViewModel)
                .task {
                    await appState.start()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: "dashboard") {
            DashboardView(appState: appState)
                .onAppear {
                    Log.app.info("Dashboard window opened")
                    NSApp.activate()
                    centerAndFloatDashboard()
                }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(settingsViewModel: appState.settingsViewModel)
        }
    }

    private func centerAndFloatDashboard() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && $0.identifier?.rawValue.contains("dashboard") == true
                    || ($0.title == "Dashboard" && $0.level == .normal)
            }) else { return }
            window.center()
            window.level = .floating
        }
    }
}
