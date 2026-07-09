import SwiftUI

struct MiniPlayerBar: View {
    @State private var player = AudioPlayerManager.shared
    @State private var showFullPlayer = false
    @State private var artworkFailed = false

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
                                .animation(.smooth(duration: 0.5), value: player.progress)
                        }
                }
                .frame(height: 3)

                HStack(spacing: 12) {
                    // Artwork
                    if !artworkFailed,
                       let url = item.bestImageURL ?? item.imageURL,
                       let imageURL = URL(string: url) {
                        CachedAsyncImage(url: imageURL, onResult: { success in
                            if !success { artworkFailed = true }
                        })
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
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }

                    // Close
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
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
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentItem != nil)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentItem?.id)
            .onChange(of: player.currentItem?.id) { _, _ in
                artworkFailed = false
            }
        }
    }
}

// MARK: - Full Player Sheet

struct FullPlayerView: View {
    @State private var player = AudioPlayerManager.shared
    @State private var artworkFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Artwork
                if !artworkFailed,
                   let item = player.currentItem,
                   let url = item.bestImageURL ?? item.imageURL,
                   let imageURL = URL(string: url) {
                    CachedAsyncImage(url: imageURL, onResult: { success in
                        if !success { artworkFailed = true }
                    })
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
                        set: { newValue in
                            // Only commit seek on meaningful drag movement
                            if abs(newValue - player.currentTime) > 0.5 {
                                player.seek(to: newValue)
                            }
                        }
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
                HStack(spacing: 60) {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        player.seekBackward(15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title)
                    }

                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: player.isPlaying)

                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        player.seekForward(15)
                    } label: {
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
                    Button("Done") {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: player.currentItem?.id) { _, _ in
            artworkFailed = false
        }
    }
}
