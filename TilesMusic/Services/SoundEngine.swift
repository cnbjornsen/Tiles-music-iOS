import Foundation
import AVFoundation
import UIKit

/// Spiller korte klik/blip-lyde og giver haptisk feedback når man rammer en tile.
/// Selve musikken kommer fra Spotify – det her er kun spil-feedback ovenpå.
final class SoundEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var hitBuffer: AVAudioPCMBuffer?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private var started = false

    func start() {
        guard !started else { return }
        configureSession()

        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        hitBuffer = makeBlip(format: format, frequency: 880, duration: 0.06)

        do {
            try engine.start()
            player.play()
            started = true
            haptics.prepare()
        } catch {
            print("SoundEngine kunne ikke starte: \(error)")
        }
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
    }

    func playHit() {
        guard started, let buffer = hitBuffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        haptics.impactOccurred()
    }

    // MARK: - Helpers

    /// Vi laver lyd-sessionen "ambient" så Spotify-musikken kan spille samtidig.
    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession-fejl: \(error)")
        }
    }

    /// Genererer en kort sinus-tone med fade-out, så det lyder som et "blip".
    private func makeBlip(format: AVAudioFormat, frequency: Double, duration: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = 1.0 - (Double(frame) / Double(frameCount)) // simpel lineær fade-out
            let value = Float(sin(2.0 * .pi * frequency * t) * envelope * 0.3)
            for channel in 0..<channels {
                buffer.floatChannelData?[channel][frame] = value
            }
        }
        return buffer
    }
}
