import SwiftUI
import UIKit

struct FeedItemCardView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    let appearDelay: Double
    var onBookmark: (() -> Void)?
    @State private var appeared = false
    @AppStorage("fontSize") private var fontSize = "medium"

    private var titleFont: Font {
        switch fontSize {
        case "small": return .subheadline
        case "large": return .title3
        default: return .headline
        }
    }

    private var bodyFont: Font {
        switch fontSize {
        case "small": return .caption
        case "large": return .body
        default: return .subheadline
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image — fixed aspect ratio guarantees every card is identical shape
            Rectangle()
                .fill(.clear)
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    Group {
                        if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                case .failure, .empty:
                                    gradientPlaceholder
                                @unknown default:
                                    gradientPlaceholder
                                }
                            }
                            .overlay(isRead ? Color.black.opacity(0.15) : nil)
                        } else {
                            gradientPlaceholder
                        }
                    }

                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .soft)
                        impact.impactOccurred()
                        onBookmark?()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.title3)
                            .foregroundStyle(isBookmarked ? .yellow : .white)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                }
                .clipped()

            // Category + source
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(categoryColor(item.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(categoryColor(item.category).opacity(0.12))
                    .clipShape(Capsule())

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(item.sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isNew {
                    Text("NEW")
                        .font(.caption2)
                        .fontWeight(.heavy)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                if isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Title
            Text(item.title)
                .font(titleFont)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundStyle(isRead ? .secondary : .primary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            // Excerpt
            Text(item.excerpt)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // Relative date + reading time
            HStack {
                Text(formattedDate(item.publishedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(readingTime)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if !isRead {
                RoundedRectangle(cornerRadius: 2)
                    .fill(categoryColor(item.category))
                    .frame(width: 3)
                    .padding(.vertical, 16)
                    .padding(.leading, 1)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .opacity(appeared ? (isRead ? 0.85 : 1) : 0)
        .offset(y: appeared ? 0 : 16)
        .contextMenu {
            Button {
                onBookmark?()
            } label: {
                Label(
                    isBookmarked ? "Remove Bookmark" : "Bookmark",
                    systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
                )
            }

            Button {
                UIPasteboard.general.url = URL(string: item.url)
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }

            Button {
                if let url = URL(string: item.url) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }

            ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(appearDelay)) {
                appeared = true
            }
        }
    }

    private var isNew: Bool {
        Date().timeIntervalSince(item.publishedAt) < 3600 // < 1 hour
    }

    private var readingTime: String {
        let wordCount = item.excerpt.split(separator: " ").count
        let minutes = max(1, Int(ceil(Double(wordCount) / 200.0)))
        return "\(minutes) min read"
    }

    // MARK: - Date Formatting

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())

        if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
            return relative
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }

    // MARK: - Helpers

    private var gradientPlaceholder: some View {
        let colors = placeholderColors
        return ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                // Source initial in a circle
                Text(String(item.sourceTitle.prefix(1)))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.2))
                    .clipShape(Circle())

                Text(item.sourceTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var placeholderColors: [Color] {
        switch item.category.lowercased() {
        case "tech": return [.blue.opacity(0.3), .indigo.opacity(0.2)]
        case "news": return [.red.opacity(0.3), .orange.opacity(0.2)]
        case "science": return [.green.opacity(0.3), .teal.opacity(0.2)]
        case "design": return [.purple.opacity(0.3), .pink.opacity(0.2)]
        case "culture": return [.orange.opacity(0.3), .yellow.opacity(0.2)]
        default: return [Color(.systemGray5), Color(.systemGray4)]
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "tech": return .blue
        case "news": return .red
        case "science": return .green
        case "design": return .purple
        case "culture": return .orange
        default: return .gray
        }
    }
}
