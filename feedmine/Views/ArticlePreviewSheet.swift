import SwiftUI
import SafariServices

struct ArticlePreviewSheet: View {
    let item: FeedItem
    @State private var showSafari = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero image
                    if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxHeight: 250)
                                    .clipped()
                            case .failure, .empty:
                                previewGradient
                                    .frame(height: 180)
                            @unknown default:
                                previewGradient
                                    .frame(height: 180)
                            }
                        }
                    } else {
                        previewGradient
                            .frame(height: 120)
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 12) {
                        // Category + source badge
                        HStack(spacing: 6) {
                            Image(systemName: categoryIcon)
                                .font(.caption)
                            Text(item.category)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(categoryColor)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(item.sourceTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(item.publishedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        // Title
                        Text(item.title)
                            .font(.title2)
                            .fontWeight(.bold)

                        // Reading time
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(readingTime)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)

                        Divider()

                        // Full excerpt
                        Text(item.excerpt)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(4)

                        // Link
                        if let url = URL(string: item.url) {
                            Text(url.host() ?? "")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .padding(.top, 4)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSafari = true
                    } label: {
                        Label("Read in Safari", systemImage: "safari")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .sheet(isPresented: $showSafari) {
                ArticleSafariView(url: URL(string: item.url) ?? URL(string: "https://feedmine.app")!)
            }
        }
    }

    private var previewGradient: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [categoryColor.opacity(0.2), categoryColor.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var readingTime: String {
        let words = item.excerpt.split(separator: " ").count
        let min = max(1, Int(ceil(Double(words) / 200.0)))
        return "\(min) min read"
    }

    private var categoryColor: Color {
        switch item.category.lowercased() {
        case "tech": return .blue
        case "news": return .red
        case "science": return .green
        case "design": return .purple
        case "culture": return .orange
        default: return .gray
        }
    }

    private var categoryIcon: String {
        switch item.category.lowercased() {
        case "tech": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "design": return "paintpalette.fill"
        case "culture": return "theatermasks.fill"
        default: return "doc.text.fill"
        }
    }
}

// MARK: - Safari View

private struct ArticleSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = true
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
