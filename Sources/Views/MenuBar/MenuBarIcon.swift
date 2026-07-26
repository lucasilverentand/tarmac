import AppKit
import SwiftUI

struct MenuBarIcon: View {
    private static let glyph: NSImage = {
        guard let source = NSImage(named: "TarmacMenuBarIcon"),
            let image = source.copy() as? NSImage
        else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    let queueViewModel: QueueViewModel
    let vmStatusViewModel: VMStatusViewModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: Self.glyph)
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)

            if let badge {
                Image(systemName: badge.systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(badge.tint)
                    .background {
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 10, height: 10)
                    }
                    .offset(x: 3, y: -2)
            }
        }
        .frame(width: 22, height: 18)
        .accessibilityLabel(accessibilityLabel)
    }

    private var badge: MenuBarIconBadge? {
        if queueViewModel.allJobs.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if queueViewModel.activeJob != nil {
            return .running
        }
        if !vmStatusViewModel.readyForJobs {
            return .notReady
        }
        return nil
    }

    private var accessibilityLabel: Text {
        switch badge {
        case .failed:
            return Text("Tarmac, job failed")
        case .running:
            return Text("Tarmac, runner active")
        case .notReady:
            return Text("Tarmac, runner not ready")
        case nil:
            return Text("Tarmac, ready")
        }
    }
}

private enum MenuBarIconBadge {
    case failed
    case running
    case notReady

    var systemImage: String {
        switch self {
        case .failed:
            return "exclamationmark.circle.fill"
        case .running:
            return "play.circle.fill"
        case .notReady:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .failed:
            return .red
        case .running:
            return .green
        case .notReady:
            return .orange
        }
    }
}
