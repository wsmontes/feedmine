import SwiftUI

struct MoodFilterBar: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FeedLoader.MoodFilter.allCases) { mood in
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            loader.selectMood(mood)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mood.icon)
                                .font(.caption2)
                            Text(mood.rawValue)
                                .font(.caption)
                        }
                        .fontWeight(loader.selectedMood == mood ? .semibold : .regular)
                        .foregroundStyle(loader.selectedMood == mood ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(loader.selectedMood == mood ? moodColor(mood) : Color(.systemGray6))
                        )
                        .scaleEffect(loader.selectedMood == mood ? 1.0 : 0.97)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: loader.selectedMood)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
    }

    private func moodColor(_ mood: FeedLoader.MoodFilter) -> Color {
        switch mood {
        case .all: return .gray
        case .serious: return .red
        case .fun: return .pink
        case .technical: return .indigo
        case .inspiring: return .orange
        }
    }
}
