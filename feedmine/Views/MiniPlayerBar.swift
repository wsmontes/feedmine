import SwiftUI

struct MiniPlayerBar: View {
    @State private var player = AudioPlayerManager.shared
    @State private var showFullPlayer = false

    var body: some View {
        if let item = player.currentItem {
            VStack(spacing: 0) {
                // Progress bar
                GeometryReader { geo in
                    Capsule()
                        .fill(.blue.opacity(0.3))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.blue)
                                .frame(width: geo.size.width * player.progress, height: 3)
                        }
                }
                .frame(height: 3)

                HStack(spacing: 12) {
                    // Artwork
                    if let url = item.bestImageURL ?? item.imageURL, let imageURL = URL(string: url) {
                        CachedAsyncImage(url: imageURL)
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))
                            .frame(width: 40, height: 40)
                            .overlay(Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary))
                    }

                    // Title + source
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(item.sourceTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Time
                    Text(player.currentTimeFormatted)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    // Play/Pause
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }

                    // Close
                    Button {
                        player.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .onTapGesture { showFullPlayer = true }
            .sheet(isPresented: $showFullPlayer) {
                FullPlayerView()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: player.currentItem?.id)
        }
    }
}

// MARK: - Full Player Sheet

struct FullPlayerView: View {
    @State private var player = AudioPlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Artwork
                if let item = player.currentItem,
                   let url = item.bestImageURL ?? item.imageURL,
                   let imageURL = URL(string: url) {
                    CachedAsyncImage(url: imageURL)
                        .scaledToFill()
                        .frame(width: 280, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(radius: 20)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemGray5))
                        .frame(width: 280, height: 280)
                        .overlay(
                            Image(systemName: "waveform")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        )
                }

                // Title + source
                VStack(spacing: 4) {
                    Text(player.currentItem?.title ?? "")
                        .font(.title3)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                    Text(player.currentItem?.sourceTitle ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)

                // Scrubber
                VStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ), in: 0...max(player.duration, 1))
                    .tint(.blue)

                    HStack {
                        Text(player.currentTimeFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(player.durationFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 32)

                // Controls
                HStack(spacing: 40) {
                    Button { player.seekBackward(15) } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title)
                    }

                    Button { player.seekBackward(15) } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                    }

                    Button { player.seekForward(15) } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }

                    Button { player.seekForward(15) } label: {
                        Image(systemName: "goforward.15")
                            .font(.title)
                    }
                }

                Spacer()

                // Podcast badge
                if let dur = player.currentItem?.durationFormatted {
                    HStack(spacing: 4) {
                        Image(systemName: "headphones")
                            .font(.caption2)
                        Text("Podcast · \(dur)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
