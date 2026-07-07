import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var allCountriesOn = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("All Countries", systemImage: "globe.americas.fill")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $allCountriesOn)
                        .labelsHidden()
                        .tint(.green)
                }
            }

            Section {
                ForEach(loader.availableCountries) { country in
                    CountryRow(country: country)
                }
            } footer: {
                let total = loader.availableCountries.map(\.feedCount).reduce(0, +)
                Text("\(loader.availableCountries.count) countries · \(total) feeds")
            }
        }
        .navigationTitle("Countries")
        .onAppear {
            allCountriesOn = loader.isAnyCountryEnabled
        }
        .onChange(of: allCountriesOn) { _, _ in
            loader.toggleAllCountries()
        }
        .onChange(of: loader.isAnyCountryEnabled) { _, newValue in
            if allCountriesOn != newValue {
                allCountriesOn = newValue
            }
        }
    }
}

// MARK: - Country Row (extracted to stabilize @Observable reads)

private struct CountryRow: View {
    @Environment(FeedLoader.self) private var loader
    let country: Country
    @State private var isOn = false

    var body: some View {
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
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .onAppear {
            isOn = loader.isRegionEnabled(country.region)
        }
        .onChange(of: isOn) { _, _ in
            loader.toggleRegion(country.region)
        }
        .onChange(of: loader.isRegionEnabled(country.region)) { _, newValue in
            if isOn != newValue {
                isOn = newValue
            }
        }
    }
}
