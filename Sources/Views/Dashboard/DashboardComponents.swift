import AppKit
import SwiftUI

struct DashboardPageHeader<Accessory: View>: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    @ViewBuilder let accessory: Accessory

    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)
            accessory
        }
    }
}

extension DashboardPageHeader where Accessory == EmptyView {
    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource
    ) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct DashboardStatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct DashboardMetricItem: View {
    let title: LocalizedStringResource
    let value: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DashboardMetricStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            content
        }
        .padding(13)
        .dashboardSurface()
    }
}

extension View {
    func dashboardSurface(tint: Color? = nil, interactive: Bool = false) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(interactive ? 0.98 : 0.90))

                if let tint {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.035))
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}
