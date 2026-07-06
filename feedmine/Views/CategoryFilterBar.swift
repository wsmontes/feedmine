import SwiftUI

struct CategoryFilterBar: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryPill(
                    title: "All",
                    isSelected: loader.selectedCategory == nil,
                    color: .gray
                ) {
                    loader.selectCategory(nil)
                }

                ForEach(loader.availableCategories, id: \.self) { category in
                    CategoryPill(
                        title: category,
                        isSelected: loader.selectedCategory == category,
                        color: categoryColor(category)
                    ) {
                        loader.selectCategory(category)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func categoryColor(_ category: String) -> Color {
        ComponentToken.categoryColor(for: category)
    }
}

struct CategoryPill: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? color : color.opacity(0.1))
                )
                .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
