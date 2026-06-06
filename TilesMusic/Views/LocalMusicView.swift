import SwiftUI
import MediaPlayer
import UniformTypeIdentifiers

/// Spil til din egen musik: vælg en sang fra dit musikbibliotek eller importér en
/// lydfil. For ikke-DRM-lyd analyseres beatet, så tiles rammer de faktiske anslag.
struct LocalMusicView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: LocalSelection?
    @State private var difficulty: Difficulty = .medium
    @State private var beatmap: Beatmap?
    @State private var playback: LocalPlaybackController?
    @State private var isBuilding = false
    @State private var showPicker = false
    @State private var showImporter = false
    @State private var errorText: String?
    @State private var goToGame = false

    var body: some View {
        NavigationStack {
            Group {
                if let selection {
                    setup(for: selection)
                } else {
                    chooser
                }
            }
            .padding()
            .navigationTitle("Egen musik")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Luk") { dismiss() } } }
            .sheet(isPresented: $showPicker) {
                MediaPicker { item in handlePicked(item) }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                handleImport(result)
            }
            .alert("Kan ikke bruge denne sang", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
            .navigationDestination(isPresented: $goToGame) {
                if let beatmap, let playback, let selection {
                    GameView(track: GameTrack(id: selection.id, name: selection.title, artist: selection.artist),
                             beatmap: beatmap, difficulty: difficulty, playback: playback)
                }
            }
        }
    }

    // MARK: - Valg af kilde

    private var chooser: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 64)).foregroundStyle(.secondary)
            Text("Vælg musik fra din enhed")
                .font(.title3.bold())
            Text("Importerede filer kan beat-analyseres for rigtig synkronisering. Beskyttede (DRM) streaming-sange kan ikke bruges lokalt.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Button { showPicker = true } label: {
                Label("Vælg fra mit musikbibliotek", systemImage: "music.note")
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .background(.tint, in: Capsule()).foregroundStyle(.white)

            Button { showImporter = true } label: {
                Label("Importér en lydfil", systemImage: "folder")
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .background(.white.opacity(0.12), in: Capsule())
            Spacer()
        }
    }

    // MARK: - Opsætning

    private func setup(for selection: LocalSelection) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text(selection.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(selection.artist).foregroundStyle(.secondary)
            }
            Picker("Sværhedsgrad", selection: $difficulty) {
                ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                Task { await build(selection) }
            } label: {
                Group {
                    if isBuilding { ProgressView().tint(.white) }
                    else { Label("Spil", systemImage: "play.fill") }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
            .foregroundStyle(.white)
            .disabled(isBuilding)

            Button("Vælg en anden") { self.selection = nil }
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Handlinger

    private func handlePicked(_ item: MPMediaItem) {
        guard let url = item.assetURL else {
            errorText = "Denne sang er beskyttet (DRM) og kan ikke afspilles eller analyseres lokalt. Prøv en importeret fil."
            return
        }
        selection = LocalSelection(id: "lib-\(item.persistentID)",
                                   title: item.title ?? "Ukendt sang",
                                   artist: item.artist ?? "Ukendt kunstner",
                                   url: url)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let local = copyToCaches(url) else { errorText = "Kunne ikke læse filen."; return }
            selection = LocalSelection(id: "file-\(local.lastPathComponent)",
                                       title: url.deletingPathExtension().lastPathComponent,
                                       artist: "Importeret fil",
                                       url: local)
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func build(_ selection: LocalSelection) async {
        isBuilding = true
        let bm = await BeatmapBuilder.build(url: selection.url, difficulty: difficulty)
        beatmap = bm
        playback = LocalPlaybackController(url: selection.url)
        isBuilding = false
        goToGame = true
    }

    /// Kopiér en importeret fil til caches, så vi har stabil adgang under spillet.
    private func copyToCaches(_ src: URL) -> URL? {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest); return dest }
        catch { return nil }
    }
}

struct LocalSelection {
    let id: String
    let title: String
    let artist: String
    let url: URL
}

// MARK: - MPMediaPickerController-wrapper

struct MediaPicker: UIViewControllerRepresentable {
    var onPick: (MPMediaItem) -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItem) -> Void
        init(onPick: @escaping (MPMediaItem) -> Void) { self.onPick = onPick }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            mediaPicker.dismiss(animated: true)
            if let item = collection.items.first { onPick(item) }
        }
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            mediaPicker.dismiss(animated: true)
        }
    }
}
