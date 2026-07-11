import SwiftUI

struct OnboardingTipsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var currentTip = 0

    /// Onboarding communicates *why* Feedmine is different — anti-algorithm,
    /// anti-bubble, respect for publishers, open-source, privacy-first.
    /// Each tip pairs a philosophy statement with a quick mechanic so the
    /// user learns both the ethos and how to act on it.
    private let tips: [(icon: String, title: String, subtitle: String, color: Color)] = [
        (
            "globe.americas.fill",
            "Stories from 190 countries",
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

                    // Current tip
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

                    // Progress dots
                    HStack(spacing: 6) {
                        ForEach(0..<tips.count, id: \.self) { i in
                            Capsule()
                                .fill(i == currentTip ? tips[i].color : Color(.systemGray4))
                                .frame(width: i == currentTip ? 16 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: currentTip)
                        }
                    }

                    // Action buttons
                    HStack {
                        Text("\(currentTip + 1) of \(tips.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(currentTip < tips.count - 1 ? "Next" : "Got it!") {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if currentTip < tips.count - 1 {
                                    currentTip += 1
                                } else {
                                    hasSeenOnboarding = true
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(tips[currentTip].color)
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
        }
    }
}
