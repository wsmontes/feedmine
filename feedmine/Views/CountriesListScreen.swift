import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        List {
            Section {
                Button {
                    loader.toggleAllCountries()
                } label: {
                    HStack {
                        Label("All Countries", systemImage: "globe.americas.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: loader.isAnyCountryEnabled
                            ? "checkmark.circle.fill"
                            : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(loader.isAnyCountryEnabled ? .green : .secondary)
                    }
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
                            Image(systemName: loader.isRegionEnabled(country.region)
                                ? "checkmark.circle.fill"
                                : "circle"
                            )
                            .font(.title3)
                            .foregroundStyle(loader.isRegionEnabled(country.region) ? .green : .secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            loader.toggleRegion(country.region)
                        } label: {
                            if loader.isRegionEnabled(country.region) {
                                Label("Disable", systemImage: "eye.slash")
                            } else {
                                Label("Enable", systemImage: "eye")
                            }
                        }
                        .tint(loader.isRegionEnabled(country.region) ? .red : .green)
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
