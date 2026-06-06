import SwiftUI

/// Resultatskærm efter en runde.
struct ResultView: View {
    let track: Track
    let score: Int
    let maxCombo: Int
    let bestScore: Int
    let isNewRecord: Bool
    let didWin: Bool
    let onDone: () -> Void

    @State private var showRecordBadge = false

    var body: some View {
        ZStack {
            LinearGradient(colors: didWin ? [.green.opacity(0.4), .black] : [.red.opacity(0.35), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: didWin ? "trophy.fill" : "flag.checkered")
                    .font(.system(size: 72))
                    .foregroundStyle(didWin ? .yellow : .white)

                Text(didWin ? "Du klarede den!" : "Game over")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))

                Text(track.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isNewRecord {
                    Label("Ny rekord!", systemImage: "star.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(.yellow.opacity(0.15), in: Capsule())
                        .scaleEffect(showRecordBadge ? 1 : 0.4)
                        .opacity(showRecordBadge ? 1 : 0)
                }

                VStack(spacing: 12) {
                    statRow(label: "Score", value: "\(score)")
                    statRow(label: "Største combo", value: "×\(maxCombo)")
                    statRow(label: "Rekord", value: "\(bestScore)")
                }
                .padding()
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 48)

                Spacer()

                Button(action: onDone) {
                    Text("Tilbage til biblioteket")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
                .padding(.horizontal, 40)

                Spacer()
            }
            .padding()
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5).delay(0.2)) {
                showRecordBadge = true
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.title3.bold())
        }
    }
}
