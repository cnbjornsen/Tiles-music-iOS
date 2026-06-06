import Foundation
import AVFoundation

/// Afspiller en lokal lydfil (importeret fil eller et bibliotekselement med assetURL)
/// via AVPlayer. Spiller hele sangen, så spillet kan synkroniseres til den.
@MainActor
final class LocalPlaybackController: ObservableObject, GamePlayback {

    var onPlaybackStarted: (() -> Void)?

    private let url: URL
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var started = false

    init(url: URL) { self.url = url }

    func begin() {
        configureSession()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p

        // Fyr "startet" så snart afspilningspositionen faktisk bevæger sig.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if time.seconds > 0 { self.fireStarted() }
        }
        p.play()
    }

    func pause() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    /// Aktuel afspilningsposition i sekunder (kan bruges til finsynk).
    func position() -> Double? {
        guard let t = player?.currentTime().seconds, t.isFinite else { return nil }
        return t
    }

    private func fireStarted() {
        guard !started else { return }
        started = true
        onPlaybackStarted?()
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession-fejl: \(error)")
        }
    }
}
