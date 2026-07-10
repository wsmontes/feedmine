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

// TEMP stubs — replaced in Task 6 / Task 7.
struct FeedCreationPage: View { var body: some View { Color.clear } }
struct FeedDotsIndicator: View { var body: some View { EmptyView() } }
