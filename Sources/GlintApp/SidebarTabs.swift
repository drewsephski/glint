import SwiftUI

/// The editor sidebar's tabs: an icon over a short label each, the selection sliding between them.
struct SidebarTabBar: View {
    @Binding var selection: SidebarTab
    /// Tabs with something waiting (a dot on the icon).
    var badges: Set<SidebarTab> = []
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases, id: \.self) { t in
                let on = t == selection
                Hoverable { hover in
                    VStack(spacing: 3) {
                        Image(systemName: t.systemImage).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .frame(height: 15)
                            .overlay(alignment: .topTrailing) {
                                if badges.contains(t) { Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 5, y: -2) }
                            }
                        Text(t.rawValue).font(.system(size: 9.5, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Theme.text : hover ? Theme.text : Theme.text2)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        } else if hover {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.05))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.22)) { selection = t } }
                }
                .help(t == .agent && badges.contains(t) ? "Activity: proposals are waiting" : t.rawValue)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(t.rawValue)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}
