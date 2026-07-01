import SwiftUI

struct OnboardingTipsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var currentTip = 0

    private let tips: [(icon: String, title: String, color: Color)] = [
        ("hand.tap.fill", "Tap any article to preview", .blue),
        ("arrow.left.square.fill", "Swipe right to mark read", .green),
        ("arrow.right.square.fill", "Swipe left to bookmark", .yellow),
        ("line.3.horizontal.decrease", "Tap to filter by category & mood", .purple),
        ("gearshape", "Customize in Settings", .orange)
    ]

    var body: some View {
        if !hasSeenOnboarding {
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    // Dismiss handle
                    Capsule()
                        .fill(Color(.systemGray4))
                        .frame(width: 32, height: 4)
                        .padding(.top, 8)

                    // Current tip
                    HStack(spacing: 12) {
                        Image(systemName: tips[currentTip].icon)
                            .font(.title2)
                            .foregroundStyle(tips[currentTip].color)
                            .frame(width: 40)
                        Text(tips[currentTip].title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
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
                                hasSeenOnboarding = true
                            }
                        }
                )
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
