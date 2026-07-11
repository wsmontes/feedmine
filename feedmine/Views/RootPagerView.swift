import SwiftUI

struct RootPagerView: View {
    @Environment(FeedManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        ZStack(alignment: .bottom) {
            TabView(selection: $manager.activeIndex) {
                ForEach(Array(manager.feeds.enumerated()), id: \.element.id) { index, instance in
                    FeedScreen()
                        .environment(instance.loader)
                        .environment(\.feedTheme, manager.theme(for: instance.descriptor))
                        .environment(\.feedName, instance.descriptor.name)
                        .tag(index)
                }
                if manager.canCreateMore {
                    FeedCreationPage()
                        .tag(manager.feeds.count)   // creation page is the last tag
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .task { await manager.startWarmUp() }
            .onChange(of: manager.activeIndex) { _, _ in manager.onActiveChanged() }

            FeedDotsIndicator()   // Task 7
        }
    }
}
