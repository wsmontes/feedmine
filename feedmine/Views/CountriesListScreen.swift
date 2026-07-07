import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        List {
            Section {
                HStack {
                    Label("All Countries", systemImage: "globe.americas.fill")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { loader.isAnyCountryEnabled },
                        set: { _ in loader.toggleAllCountries() }
                    ))
                    .labelsHidden()
                    .tint(.green)
                }
            }

            Section {
                ForEach(loader.availableCountries) { country in
                    NavigationLink {
                        CountryDetailScreen(country: country)
                    } label: {
                        HStack(spacing: 12) {
                            Text(country.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(country.name).font(.body)
                                Text("\(country.feedCount) feeds")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { loader.isRegionEnabled(country.region) },
                                set: { _ in loader.toggleRegion(country.region) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                }
            } footer: {
                let total = loader.availableCountries.map(\.feedCount).reduce(0, +)
                Text("\(loader.availableCountries.count) countries · \(total) feeds")
            }
        }
        .navigationTitle("Countries")
    }
}
