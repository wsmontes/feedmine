import SwiftUI

struct ErrorBannerView: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        if loader.fetchErrorCount > 0 && loader.loadingState != .initial {
            Button {
                Task {
                    await loader.refresh()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("\(loader.fetchErrorCount) feed\(loader.fetchErrorCount == 1 ? "" : "s") failed to load")
                        .font(.caption)
                    Spacer()
                    Text("Tap to retry")
                        .font(.caption)
                        .fontWeight(.medium)
                        .underline()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.9))
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: loader.fetchErrorCount)
        }
    }
}
