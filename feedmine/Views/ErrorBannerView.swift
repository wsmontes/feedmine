import SwiftUI

struct ErrorBannerView: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 0) {
            // Offline banner
            if !loader.networkMonitor.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("No internet connection")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.85))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Reconnected banner
            if loader.networkMonitor.isConnected
                && loader.networkMonitor.wasDisconnected
                && loader.fetchErrorCount > 0
                && loader.loadingState != .initial {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.caption)
                    Text("Back online")
                        .font(.caption)
                    Spacer()
                    Button {
                        Task { await loader.refresh() }
                    } label: {
                        Text("Refresh")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .underline()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.85))
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    loader.networkMonitor.wasDisconnected = false
                }
            }

            // Fetch error banner
            if loader.fetchErrorCount > 0
                && loader.loadingState != .initial
                && loader.networkMonitor.isConnected {
                Button {
                    Task { await loader.refresh() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text("\(loader.fetchErrorCount) feed\(loader.fetchErrorCount == 1 ? "" : "s") failed")
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
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loader.networkMonitor.isConnected)
        .animation(.easeInOut(duration: 0.3), value: loader.fetchErrorCount)
    }
}
