import SwiftUI

struct RootPagerView: View {
    @Environment(FeedManager.self) private var manager
    @Environment(LocaleManager.self) private var localeManager

    var body: some View {
        @Bindable var manager = manager
        ZStack(alignment: .bottom) {
            TabView(selection: $manager.activeIndex) {
                ForEach(Array(manager.feeds.enumerated()), id: \.element.id) { index, instance in
                    FeedScreen()
                        .environment(instance.loader)
                        .environment(\.feedTheme, manager.theme(for: instance.descriptor))
                        .tag(index)
                }
                if manager.canCreateMore {
                    FeedCreationPage()
                        .tag(manager.feeds.count)   // creation page is the last tag
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            FeedDotsIndicator()   // Task 7
        }
    }
}

// TEMP stub — replaced in Task 7.
struct FeedDotsIndicator: View { var body: some View { EmptyView() } }
