import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        let countries = loader.availableCountries
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
                ForEach(countries) { country in
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
                let total = countries.map(\.feedCount).reduce(0, +)
                Text("\(countries.count) countries · \(total) feeds")
            }
        }
        .navigationTitle("Countries")
    }
}
