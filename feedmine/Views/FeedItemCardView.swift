import SwiftUI
import UIKit

struct FeedItemCardView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    var onBookmark: (() -> Void)?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image with bookmark overlay
            ZStack(alignment: .topTrailing) {
                if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 180)
                                .clipped()
                                .overlay(isRead ? Color.black.opacity(0.15) : nil)
                        case .failure, .empty:
                            gradientPlaceholder.frame(height: 180)
                        @unknown default:
                            gradientPlaceholder.frame(height: 180)
                        }
                    }
                }

                // Bookmark button
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
            .frame(height: item.imageURL != nil ? 180 : 0)
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

                Spacer()

                if isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Title
            Text(item.title)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundStyle(isRead ? .secondary : .primary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            // Excerpt
            Text(item.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            // Relative date
            HStack {
                Text(formattedDate(item.publishedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .opacity(appeared ? (isRead ? 0.7 : 1) : 0)
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
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
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
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(.systemGray5), Color(.systemGray4)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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
