import SwiftUI

struct MomentCard: View {
    @Environment(FeedLoader.self) private var loader
    @State private var greeting: String = ""

    private var ctx: AppContext { AppContext.shared }

    var body: some View {
        if !loader.items.isEmpty {
            Text(MomentGreeting.generate())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                    AppContext.shared.refresh()
                }
        }
    }
}
