import SwiftUI

/// Shared structure for every tool: title top-left, content below, pinned top.
/// This is what stops panels floating in the middle of empty space.
struct ToolContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No title here on purpose: ExpandedView's header already shows the
            // tool name top-left. Rendering it again wasted a row and shrank content.
            if let s = subtitle {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
