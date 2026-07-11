import SwiftUI

/// The blank "new feed" page at the right edge of the pager. Shows the feed's
/// future color (next free palette) as a preview, collects an optional name,
/// and on OK creates the feed and jumps into it. Draft is cleared on disappear.
struct FeedCreationPage: View {
    @Environment(FeedManager.self) private var manager
    @State private var name: String = ""

    private var previewFamily: PaletteFamily? { manager.nextFreeFamily }
    private var previewAccent: Color {
        guard let f = previewFamily else { return .gray }
        return f.accent(for: CircadianEngine.shared.period)
    }

    var body: some View {
        ZStack {
            (previewFamily?.pageTint(for: CircadianEngine.shared.period) ?? Color(hex: "#FAF8F5"))
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(previewAccent)
                Text("New Feed").font(.title2.bold())
                Text("A fresh, independent feed with its own sources and color.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)

                TextField("Feed name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 40)

                Button {
                    manager.createFeed(name: name)
                } label: {
                    Text("Create Feed").font(.headline)
                        .frame(maxWidth: .infinity).padding()
                        .background(previewAccent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 40)
                .disabled(previewFamily == nil)
                Spacer()
            }
        }
        .onDisappear { name = "" }   // clear draft on exit
    }
}
