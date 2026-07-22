import SwiftUI

struct FeedItemRowView: View {
    let item: FeedItem
    let isRead: Bool
    let isBookmarked: Bool
    var onImageTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thumbnail — real image, podcast placeholder, or nothing
            if item.hasPotentialImage || item.isPodcast {
                Group {
                    if item.isPodcast && !item.hasPotentialImage {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.purple.opacity(0.15))
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.purple.opacity(0.5))
                                    .offset(x: 1)
                            }
                    } else {
                        CachedAsyncImage(
                            url: item.bestImageURL.flatMap(URL.init(string:)),
                            articleURL: item.canResolveArticleImage ? URL(string: item.url) : nil
                        )
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(isRead ? Color.black.opacity(0.15) : nil)
                .overlay {
                    if onImageTap != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded { onImageTap?() })
                    }
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.category)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(categoryColor(item.category))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.sourceTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundStyle(isRead ? .secondary : .primary)

                Text(formattedDate(item.publishedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .opacity(isRead ? 0.7 : 1)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        // Reuse a cached formatter — allocating RelativeDateTimeFormatter per
        // row (this runs on every row render) is expensive. Safe as a shared
        // static: rows render on the main actor. Matches FeedItemCardView.
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}
