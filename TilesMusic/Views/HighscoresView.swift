import SwiftUI

/// Viser alle lokale rekorder samlet, sorteret med højeste score først.
struct HighscoresView: View {
    @State private var entries: [HighscoreStore.Entry] = HighscoreStore.all()
    @State private var showResetConfirm = false

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Ingen rekorder endnu",
                                       systemImage: "trophy",
                                       description: Text("Spil en sang for at sætte din første rekord."))
            } else {
                List {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 14) {
                            rankBadge(index + 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.body.weight(.semibold)).lineLimit(1)
                                Text("\(entry.artist) · \(entry.difficulty)")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(entry.score)")
                                .font(.title3.weight(.heavy).monospacedDigit())
                                .foregroundStyle(.yellow)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Highscores")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Slet alle rekorder?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Slet alle", role: .destructive) {
                HighscoreStore.reset()
                entries = []
            }
            Button("Annuller", role: .cancel) {}
        }
        .onAppear { entries = HighscoreStore.all() }
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int) -> some View {
        let color: Color = rank == 1 ? .yellow : (rank == 2 ? .gray : (rank == 3 ? .orange : .secondary))
        ZStack {
            Circle().fill(color.opacity(0.2)).frame(width: 34, height: 34)
            Text("\(rank)").font(.subheadline.weight(.bold)).foregroundStyle(color)
        }
    }
}
