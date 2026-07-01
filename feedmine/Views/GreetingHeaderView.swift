import SwiftUI

struct GreetingHeaderView: View {
    @Environment(FeedLoader.self) private var loader
    @AppStorage("accentColorName") private var accentColorName = "blue"

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    private var emoji: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<22: return "sunset.fill"
        default: return "moon.stars.fill"
        }
    }

    private var unreadCount: Int {
        loader.items.count - loader.readItemIDs.count
    }

    private var newSinceLastOpen: Int {
        // Approximate: items loaded minus those read
        max(0, loader.totalFetched - loader.readItemIDs.count)
    }

    var body: some View {
        if loader.loadingState != .initial && !loader.items.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: emoji)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(greeting)
                            .font(.title3)
                            .fontWeight(.bold)
                    }

                    HStack(spacing: 8) {
                        if unreadCount > 0 {
                            Label("\(unreadCount) unread", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        if loader.bookmarkedIDs.count > 0 {
                            Label("\(loader.bookmarkedIDs.count) saved", systemImage: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(loader.sourceCount) sources")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Quick action: refresh
                Button {
                    Task { await loader.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray6))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }
}
