import SwiftUI
import UIKit

struct OnboardingTipsView: View {
    @Environment(FeedLoader.self) private var loader
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var taxonomy = TaxonomyStore.shared
    @State private var currentTip = 0
    @State private var selectedInterestIDs: Set<String> = []
    @State private var didSeedExistingSelection = false

    private struct InterestDefinition: Identifiable {
        let id: String
        let name: String
        let icon: String
    }

    private struct InterestOption: Identifiable {
        let id: String
        let name: String
        let icon: String
        let feedCount: Int
    }

    /// Onboarding communicates *why* Feedmine is different — anti-algorithm,
    /// anti-bubble, respect for publishers, open-source, privacy-first.
    /// Each tip pairs a philosophy statement with a quick mechanic so the
    /// user learns both the ethos and how to act on it.
    private let tips: [(icon: String, title: String, subtitle: String, color: Color)] = [
        (
            "globe.americas.fill",
            "Stories from around the world",
            "Not just your corner of the world. Tap Sources to explore by country and region.",
            .teal
        ),
        (
            "brain.head.profile",
            "No AI deciding what you see",
            "You pick the sources. The feed shows everything fairly — not just what drives clicks.",
            .indigo
        ),
        (
            "newspaper.fill",
            "We send readers to publishers",
            "Articles open on the original site. Publishers get the traffic they deserve.",
            .blue
        ),
        (
            "lock.shield.fill",
            "Open source. Zero tracking.",
            "Built in public by one developer. No ads, no accounts, no investors to please.",
            .green
        ),
        (
            "hand.raised.fill",
            "Your data stays on your device",
            "Bookmarks, read history, preferences — all local. Swipe left to save, right to mark read.",
            .orange
        )
    ]

    /// Names are editorial labels stored inside the OPML hierarchy. Resolving
    /// them from the live taxonomy keeps onboarding aligned when a node moves
    /// to another file or folder and avoids maintaining a second feed list.
    private let interestDefinitions: [InterestDefinition] = [
        .init(id: "world-news", name: "World News", icon: "globe"),
        .init(id: "books", name: "Books & Literature", icon: "books.vertical"),
        .init(id: "film", name: "Film & Television", icon: "film"),
        .init(id: "software", name: "Software & Computing", icon: "laptopcomputer"),
        .init(id: "space", name: "Space & Astronomy", icon: "sparkles"),
        .init(id: "health", name: "Medicine & Public Health", icon: "heart.text.square"),
        .init(id: "sports", name: "Team & Individual Sports", icon: "sportscourt"),
        .init(id: "food", name: "Cooking & Recipes", icon: "fork.knife"),
        .init(id: "travel", name: "Travel", icon: "airplane"),
        .init(id: "history", name: "History", icon: "building.columns"),
        .init(id: "society", name: "Society & Communities", icon: "person.3"),
        .init(id: "games", name: "Video Games", icon: "gamecontroller"),
        .init(id: "pets", name: "Pets", icon: "pawprint"),
        .init(id: "music", name: "Music", icon: "music.note")
    ]

    private var interestOptions: [InterestOption] {
        interestDefinitions.compactMap { definition in
            guard let node = taxonomy.search(definition.name).first(where: {
                $0.name.compare(
                    definition.name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) else { return nil }
            return InterestOption(
                id: node.id,
                name: definition.name,
                icon: definition.icon,
                feedCount: node.feedCount
            )
        }
    }

    private var isInterestStep: Bool { currentTip == tips.count }
    private var totalSteps: Int { tips.count + 1 }
    private var accentColor: Color { isInterestStep ? .purple : tips[currentTip].color }

    var body: some View {
        if !hasSeenOnboarding {
            VStack {
                Spacer()
                VStack(spacing: 14) {
                    // Dismiss handle
                    Capsule()
                        .fill(Color(.systemGray4))
                        .frame(width: 32, height: 4)
                        .padding(.top, 8)

                    currentStep

                    // Progress dots
                    HStack(spacing: 6) {
                        ForEach(0..<totalSteps, id: \.self) { i in
                            Capsule()
                                .fill(i == currentTip ? accentColor : Color(.systemGray4))
                                .frame(width: i == currentTip ? 16 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: currentTip)
                        }
                    }

                    // Action buttons
                    HStack {
                        Text("\(currentTip + 1) of \(totalSteps)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(currentTip < totalSteps - 1 ? "Next" : "Start reading") {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if currentTip < totalSteps - 1 {
                                    currentTip += 1
                                } else {
                                    finishOnboarding()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accentColor)
                        .accessibilityIdentifier(isInterestStep ? "onboarding-start-reading" : "onboarding-next")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            if value.translation.height > 50 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    hasSeenOnboarding = true
                                }
                            }
                        }
                )
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { seedExistingSelectionIfNeeded() }
        }
    }

    @ViewBuilder
    private var currentStep: some View {
        if isInterestStep {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .foregroundStyle(.purple)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What should your first feed feel like?")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Pick any interests. You can mix, change, or clear them later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if interestOptions.isEmpty {
                    Text("Your catalog is still preparing. Start reading now and choose topics from Filters later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(interestOptions) { option in
                                interestChip(option)
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
            }
            .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: tips[currentTip].icon)
                        .font(.title2)
                        .foregroundStyle(tips[currentTip].color)
                        .frame(width: 36)
                    Text(tips[currentTip].title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                Text(tips[currentTip].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
            }
            .padding(.horizontal, 20)
        }
    }

    private func interestChip(_ option: InterestOption) -> some View {
        let isSelected = selectedInterestIDs.contains(option.id)
        return Button {
            if isSelected {
                selectedInterestIDs.remove(option.id)
            } else {
                selectedInterestIDs.insert(option.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text("\(option.feedCount) sources")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill") }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Color.purple : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-interest-\(option.id)")
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }

    private func seedExistingSelectionIfNeeded() {
        guard !didSeedExistingSelection else { return }
        didSeedExistingSelection = true
        let availableIDs = Set(interestOptions.map(\.id))
        selectedInterestIDs = loader.selectedNodeIDs.intersection(availableIDs)
    }

    private func finishOnboarding() {
        if !selectedInterestIDs.isEmpty {
            loader.applyOnboardingTopics(selectedInterestIDs)
        }
        hasSeenOnboarding = true
    }
}
