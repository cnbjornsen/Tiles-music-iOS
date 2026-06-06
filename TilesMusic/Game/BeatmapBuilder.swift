import Foundation
import AVFoundation

/// Bygger et beatmap til en lokal lydfil.
///
/// Når vi har adgang til den rå lyd (ikke-DRM), analyserer vi den grundigt og placerer
/// tiles på de faktiske anslag i musikken – altså RIGTIG synkronisering, ikke kun BPM.
/// Analysen estimerer også et lokalt tempo, fordeler tiles på baner efter anslagenes
/// styrke, laver hold-tiles ved lange/holdte toner og akkorder ved tætte dobbeltanslag,
/// så det føles som om man "spiller" takterne. Resultatet caches på disk pr. fil +
/// sværhedsgrad, så næste runde starter med det samme.
enum BeatmapBuilder {

    static func build(url: URL, difficulty: Difficulty) async -> Beatmap {
        // 1) Prøv cache.
        if let cached = Cache.load(url: url, difficulty: difficulty) {
            return cached
        }
        // 2) Analyser lyden.
        if let analysed = try? await analyse(url: url, difficulty: difficulty), analysed.tiles.count > 8 {
            Cache.save(analysed, url: url, difficulty: difficulty)
            return analysed
        }
        // 3) Fald tilbage til procedural BPM.
        let duration = (try? await durationSeconds(url: url)) ?? 120
        let map = BeatmapGenerator.make(bpm: 0, durationSeconds: duration,
                                        difficulty: difficulty, seed: seed(forTrackID: url.lastPathComponent))
        Cache.save(map, url: url, difficulty: difficulty)
        return map
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

        // 2) Onset-detektion med glidende gennemsnit. Vi gemmer både tidspunkt OG styrke.
        let window = max(1, Int(1.0 / frameDuration))   // ~1 sekunds glidende gennemsnit
        let minGap = 0.12                               // mindste afstand mellem anslag
        struct Onset { let time: Double; let strength: Float }
        var onsets: [Onset] = []
        var lastOnset = -1.0
        var running: Float = 0

        for i in 1..<energies.count {
            let start = max(0, i - window)
            if i - start == window, start > 0 { running -= energies[start - 1] }
            running += energies[i - 1]
            let avg = max(running / Float(min(i, window)), 1e-9)

            let t = Double(i) * frameDuration
            if energies[i] > avg * 1.4, energies[i] > energies[i - 1], t - lastOnset > minGap {
                onsets.append(Onset(time: t, strength: energies[i] / avg))
                lastOnset = t
            }
        }

        guard onsets.count > 8 else { throw BuilderError.tooShort }

        // 3) Estimér lokalt tempo ud fra median-afstanden mellem anslag – bruges til
        //    at sætte naturlige hold-længder, så de følger taktens puls.
        var intervals: [Double] = []
        for i in 1..<onsets.count { intervals.append(onsets[i].time - onsets[i - 1].time) }
        let sortedIntervals = intervals.sorted()
        let beat = sortedIntervals[sortedIntervals.count / 2]               // median
        let secondsPerBeat = (beat > 0.2 && beat < 1.2) ? beat : 0.5

        // 4) Fordel anslag på baner efter styrke (kvantiler), så svage og kraftige
        //    anslag lander i forskellige baner → man følger musikkens dynamik.
        let strengths = onsets.map { $0.strength }.sorted()
        func lane(for strength: Float) -> Int {
            // 4 baner: del styrke-spektret i fire kvantiler.
            let q1 = strengths[strengths.count / 4]
            let q2 = strengths[strengths.count / 2]
            let q3 = strengths[strengths.count * 3 / 4]
            if strength < q1 { return 0 }
            if strength < q2 { return 1 }
            if strength < q3 { return 2 }
            return 3
        }

        // 5) Byg tiles. Sværhedsgrad styrer tætheden.
        let keepEvery = difficulty == .easy ? 2 : 1
        var rng = SeededGenerator(seed: seed(forTrackID: url.lastPathComponent))
        var tiles: [Tile] = []
        var prevLane = -1

        var index = 0
        while index < onsets.count {
            let onset = onsets[index]
            if onset.time >= maxSeconds { break }
            if index % keepEvery != 0 { index += 1; continue }

            var laneFor = lane(for: onset.strength)
            if laneFor == prevLane { laneFor = (laneFor + 1) % kLaneCount }

            // Hold-tile: hvis der er et langt mellemrum til næste anslag (sustained tone),
            // laver vi en hold der varer indtil lige før næste anslag.
            let gap = index + 1 < onsets.count ? onsets[index + 1].time - onset.time : 0
            let holdRoll = Double(rng.next() % 1000) / 1000.0
            if gap > secondsPerBeat * 1.8, holdRoll < difficulty.holdChance + 0.25 {
                let holdDuration = min(gap - secondsPerBeat * 0.4, secondsPerBeat * 4)
                tiles.append(Tile(lane: laneFor, time: onset.time, duration: max(holdDuration, secondsPerBeat)))
                prevLane = laneFor
                index += 1
                continue
            }

            tiles.append(Tile(lane: laneFor, time: onset.time))
            prevLane = laneFor

            // Akkord: hvis næste anslag er meget tæt på (samme slag), placér det i en
            // anden bane på samme tid i stedet for som en separat tile.
            if difficulty.chordChance > 0, index + 1 < onsets.count {
                let nextGap = onsets[index + 1].time - onset.time
                let chordRoll = Double(rng.next() % 1000) / 1000.0
                if nextGap < secondsPerBeat * 0.35, chordRoll < difficulty.chordChance + 0.2 {
                    var second = lane(for: onsets[index + 1].strength)
                    if second == laneFor { second = (second + 1) % kLaneCount }
                    tiles.append(Tile(lane: second, time: onset.time))
                    prevLane = second
                    index += 2          // forbrug begge anslag som én akkord
                    continue
                }
            }

            index += 1
        }

        let estimatedBPM = secondsPerBeat > 0 ? 60.0 / secondsPerBeat : 120
        return Beatmap(bpm: estimatedBPM, tiles: tiles)
    }

    private static func durationSeconds(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 120
    }

    enum BuilderError: Error { case noAudio, cannotRead, tooShort }

    // MARK: - Cache

    /// Gemmer/henter et analyseret beatmap fra disk, så samme sang + sværhedsgrad
    /// ikke skal analyseres igen.
    private enum Cache {
        private struct StoredTile: Codable { let lane: Int; let time: Double; let duration: Double }
        private struct StoredBeatmap: Codable { let bpm: Double; let tiles: [StoredTile] }

        private static func fileURL(url: URL, difficulty: Difficulty) -> URL? {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let key = "\(url.lastPathComponent)-\(size)-\(difficulty.rawValue)".addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
            return caches.appendingPathComponent("beatmap-\(key).json")
        }

        static func load(url: URL, difficulty: Difficulty) -> Beatmap? {
            guard let file = fileURL(url: url, difficulty: difficulty),
                  let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(StoredBeatmap.self, from: data)
            else { return nil }
            let tiles = stored.tiles.map { Tile(lane: $0.lane, time: $0.time, duration: $0.duration) }
            return Beatmap(bpm: stored.bpm, tiles: tiles)
        }

        static func save(_ beatmap: Beatmap, url: URL, difficulty: Difficulty) {
            guard let file = fileURL(url: url, difficulty: difficulty) else { return }
            let stored = StoredBeatmap(bpm: beatmap.bpm,
                                       tiles: beatmap.tiles.map { StoredTile(lane: $0.lane, time: $0.time, duration: $0.duration) })
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: file)
            }
        }
    }
}
