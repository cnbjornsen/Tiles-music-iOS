import Foundation
import AVFoundation

/// Bygger et beatmap til en lokal lydfil.
///
/// Når vi har adgang til den rå lyd (ikke-DRM), analyserer vi den og placerer tiles
/// på de faktiske beats/anslag i musikken – altså RIGTIG synkronisering, ikke kun BPM.
/// Hvis analysen fejler, falder vi tilbage til det procedurale BPM-beatmap.
enum BeatmapBuilder {

    static func build(url: URL, difficulty: Difficulty) async -> Beatmap {
        if let analysed = try? await analyse(url: url, difficulty: difficulty), analysed.tiles.count > 8 {
            return analysed
        }
        let duration = (try? await durationSeconds(url: url)) ?? 120
        return BeatmapGenerator.make(bpm: 0, durationSeconds: duration,
                                     difficulty: difficulty, seed: seed(forTrackID: url.lastPathComponent))
    }

    // MARK: - Analyse

    private static let maxSeconds = 180.0   // højst 3 minutter pr. runde

    private static func analyse(url: URL, difficulty: Difficulty) async throws -> Beatmap {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw BuilderError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BuilderError.cannotRead }
        reader.add(output)
        reader.startReading()

        // 1) Energi-envelope: gennemsnitlig effekt pr. lille vindue af samples.
        let frameSize = 1024
        let frameDuration = Double(frameSize) / sampleRate
        var energies: [Float] = []
        var acc: Float = 0
        var n = 0

        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sb) {
                var length = 0
                var dataPtr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPtr)
                if let dataPtr, length > 0 {
                    let count = length / MemoryLayout<Float>.size
                    dataPtr.withMemoryRebound(to: Float.self, capacity: count) { fptr in
                        for i in 0..<count {
                            let s = fptr[i]
                            acc += s * s
                            n += 1
                            if n == frameSize { energies.append(acc / Float(frameSize)); acc = 0; n = 0 }
                        }
                    }
                }
            }
            CMSampleBufferInvalidate(sb)
            if Double(energies.count) * frameDuration > maxSeconds { break }
        }

        guard energies.count > 16 else { throw BuilderError.tooShort }

        // 2) Onset-detektion: et anslag dér hvor energien springer over et glidende gennemsnit.
        let window = max(1, Int(1.0 / frameDuration))   // ~1 sekunds glidende gennemsnit
        let minGap = 0.16                               // mindste afstand mellem anslag
        var onsets: [Double] = []
        var lastOnset = -1.0
        var running: Float = 0

        for i in 1..<energies.count {
            let start = max(0, i - window)
            // glidende gennemsnit (billigt nok ved disse størrelser)
            if i - start == window, start > 0 { running -= energies[start - 1] }
            running += energies[i - 1]
            let avg = running / Float(min(i, window))

            let t = Double(i) * frameDuration
            if energies[i] > avg * 1.4, energies[i] > energies[i - 1], t - lastOnset > minGap {
                onsets.append(t)
                lastOnset = t
            }
        }

        // 3) Byg tiles ud fra anslagene. Sværhedsgrad styrer tætheden.
        let keepEvery = difficulty == .easy ? 2 : 1
        var rng = SeededGenerator(seed: seed(forTrackID: url.lastPathComponent))
        var tiles: [Tile] = []
        var lastLane = -1
        for (index, t) in onsets.enumerated() where t < maxSeconds {
            if index % keepEvery != 0 { continue }
            var lane = Int(rng.next() % UInt64(kLaneCount))
            if lane == lastLane { lane = (lane + 1) % kLaneCount }
            lastLane = lane
            tiles.append(Tile(lane: lane, time: t))
        }

        return Beatmap(bpm: 120, tiles: tiles)
    }

    private static func durationSeconds(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 120
    }

    enum BuilderError: Error { case noAudio, cannotRead, tooShort }
}
