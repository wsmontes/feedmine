import SwiftUI

struct StatsShareCard: View {
    let readCount: Int
    let bookmarkCount: Int
    let streakCount: Int
    let topCategory: String
    let sourceCount: Int

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Feedmine")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Text("My Stats")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            // Stats grid
            HStack(spacing: 0) {
                StatBlock(value: "\(readCount)", label: "Read", icon: "eye.fill", color: .blue)
                Divider().frame(height: 50)
                StatBlock(value: "\(bookmarkCount)", label: "Saved", icon: "bookmark.fill", color: .yellow)
                Divider().frame(height: 50)
                StatBlock(value: "\(streakCount)", label: "Day Streak", icon: "flame.fill", color: .orange)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            // Details
            VStack(spacing: 8) {
                HStack {
                    Text("Top Category")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(topCategory)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sourceCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            // Footer
            HStack {
                Text("via feedmine.app")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(Date(), style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Color(.systemBackground))
        .frame(width: 340)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
    }
}

struct StatBlock: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title)
                .fontWeight(.heavy)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Render helper

@MainActor
func renderStatsCard(
    readCount: Int,
    bookmarkCount: Int,
    streakCount: Int,
    topCategory: String,
    sourceCount: Int
) -> UIImage? {
    let view = StatsShareCard(
        readCount: readCount,
        bookmarkCount: bookmarkCount,
        streakCount: streakCount,
        topCategory: topCategory,
        sourceCount: sourceCount
    )
    .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
}
