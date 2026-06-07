import Foundation
import AVFoundation
import UIKit

/// Spiller korte feedback-lyde under spillet. Vi spiller IKKE klik ved hvert hit
/// (det ødelægger musikken) – kun når man mister et liv og når man dør.
final class SoundEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var lifeLostBuffer: AVAudioPCMBuffer?
    private var gameOverBuffer: AVAudioPCMBuffer?
    private let haptics = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()
    private var started = false

    func start() {
        guard !started else { return }
        configureSession()

        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Kort, lavt "thud" når man mister et liv.
        lifeLostBuffer = makeTone(format: format, from: 320, to: 140, duration: 0.18, volume: 0.45)
        // Længere, faldende "game over"-tone.
        gameOverBuffer = makeTone(format: format, from: 440, to: 90, duration: 0.9, volume: 0.5)

        do {
            try engine.start()
            player.play()
            started = true
            haptics.prepare()
            notify.prepare()
        } catch {
            print("SoundEngine kunne ikke starte: \(error)")
        }
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
        // Giv lyd-fokus tilbage til Spotify så musikken ikke kan blive "kvalt".
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func playLifeLost() {
        guard started, let buffer = lifeLostBuffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        haptics.impactOccurred()
    }

    func playGameOver() {
        guard started, let buffer = gameOverBuffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        notify.notificationOccurred(.error)
    }

    // MARK: - Helpers

    /// Lyd-sessionen er "ambient" + mixWithOthers, så Spotify-musikken kan spille samtidig.
    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession-fejl: \(error)")
        }
    }

    /// Genererer en tone der glider fra én frekvens til en anden med fade-out.
    private func makeTone(format: AVAudioFormat, from startFreq: Double, to endFreq: Double,
                          duration: Double, volume: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        var phase = 0.0
        for frame in 0..<Int(frameCount) {
            let progress = Double(frame) / Double(frameCount)
            let freq = startFreq + (endFreq - startFreq) * progress
            phase += 2.0 * .pi * freq / sampleRate
            let envelope = 1.0 - progress                      // lineær fade-out
            let value = Float(sin(phase) * envelope * volume)
            for channel in 0..<channels {
                buffer.floatChannelData?[channel][frame] = value
            }
        }
        return buffer
    }
}
