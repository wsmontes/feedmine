import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private(set) var currentItem: FeedItem?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private init() {
        setupAudioSession()
        setupEndPlaybackObserver()
    }

    // MARK: - Audio Session (background playback)

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            print("AudioSession category failed: \(error)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession activate failed: \(error)")
        }
    }

    // MARK: - Playback ended observer

    private func setupEndPlaybackObserver() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime).prefix(1) {
                break
            }
        }
    }

    // MARK: - Playback

    func play(item: FeedItem) {
        guard let urlString = item.audioURL, let url = URL(string: urlString) else { return }

        if currentItem?.id == item.id {
            activateSession()
            player?.play()
            isPlaying = true
            return
        }

        stop()
        activateSession()
        currentItem = item
        duration = item.duration ?? 0

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.play()
        isPlaying = true

        // End observer for this item. Capture the token so stop() can remove
        // it — otherwise every new item leaks another NotificationCenter
        // observer that is never torn down.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }

        // Periodic time observer
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                if self.duration == 0, let dur = self.player?.currentItem?.duration.seconds, dur.isFinite {
                    self.duration = dur
                }
            }
        }
    }

    func togglePlayPause() {
        guard player != nil else { return }
        activateSession()
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }

    func seekForward(_ seconds: Double = 15) {
        let new = min(currentTime + seconds, duration)
        seek(to: new)
    }

    func seekBackward(_ seconds: Double = 15) {
        let new = max(currentTime - seconds, 0)
        seek(to: new)
    }

    func stop() {
        player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player = nil
        timeObserver = nil
        endObserver = nil
        currentItem = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    // MARK: - Helpers

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var currentTimeFormatted: String { formatTime(currentTime) }
    var durationFormatted: String { formatTime(duration) }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
