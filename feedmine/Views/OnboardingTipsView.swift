import SwiftUI

struct OnboardingTipsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var currentTip = 0
    @State private var opacity = 1.0

    private let tips: [(icon: String, title: String, description: String, color: Color)] = [
        ("hand.tap.fill", "Tap to Read", "Tap any article to open it in Safari with Reader mode enabled.", .blue),
        ("arrow.left.square.fill", "Swipe Right", "Swipe right on an article to mark it as read.", .green),
        ("arrow.right.square.fill", "Swipe Left", "Swipe left on an article to bookmark it for later.", .yellow),
        ("rectangle.grid.1x2.fill", "Choose Layout", "Toggle between card and compact list views using the layout switcher.", .purple),
        ("magnifyingglass", "Search & Filter", "Use the search bar and category pills to find exactly what you want.", .orange)
    ]

    var body: some View {
        if !hasSeenOnboarding {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissTips()
                    }

                VStack(spacing: 24) {
                    Spacer()

                    // Tip card
                    VStack(spacing: 16) {
                        Image(systemName: tips[currentTip].icon)
                            .font(.system(size: 48))
                            .foregroundStyle(tips[currentTip].color)

                        Text(tips[currentTip].title)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(tips[currentTip].description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        // Progress dots
                        HStack(spacing: 8) {
                            ForEach(0..<tips.count, id: \.self) { i in
                                Circle()
                                    .fill(i == currentTip ? tips[i].color : Color(.systemGray4))
                                    .frame(width: 8, height: 8)
                            }
                        }

                        // Buttons
                        HStack(spacing: 16) {
                            Button("Skip") {
                                dismissTips()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Button(currentTip < tips.count - 1 ? "Next" : "Got it!") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    if currentTip < tips.count - 1 {
                                        currentTip += 1
                                    } else {
                                        dismissTips()
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(tips[currentTip].color)
                        }
                    }
                    .padding(32)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 24)
                    .shadow(radius: 20)

                    Spacer()
                }
                .transition(.opacity)
            }
        }
    }

    private func dismissTips() {
        withAnimation(.easeOut(duration: 0.3)) {
            hasSeenOnboarding = true
        }
    }
}
