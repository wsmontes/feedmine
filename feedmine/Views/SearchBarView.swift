import SwiftUI

struct SearchBarView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Search articles...", text: $text)
                    .font(.subheadline)
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in
                        loader.searchQuery = newValue
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                        loader.searchQuery = ""
                        isFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if isFocused {
                Button("Cancel") {
                    text = ""
                    loader.searchQuery = ""
                    isFocused = false
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
