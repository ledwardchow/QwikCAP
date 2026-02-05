import SwiftUI

struct TrafficListView: View {
    @EnvironmentObject var trafficStore: TrafficStore
    @EnvironmentObject var proxyConfig: ProxyConfiguration

    @State private var selectedFilter: TrafficFilter = .all
    @State private var searchText = ""
    @State private var selectedEntry: TrafficEntry?
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Status bar
                if !proxyConfig.localInspectionEnabled {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Enable Local Traffic Inspection in Settings to capture traffic")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                }

                // Filter bar
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(TrafficFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Traffic count
                HStack {
                    Text("\(filteredEntries.count) requests")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if trafficStore.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 4)

                // Traffic list
                if filteredEntries.isEmpty {
                    emptyStateView
                } else {
                    List(filteredEntries) { entry in
                        TrafficRowView(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEntry = entry
                            }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        trafficStore.refresh()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Filter by URL or host")
            .navigationTitle("Traffic")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingClearConfirmation = true }) {
                        Image(systemName: "trash")
                    }
                    .disabled(trafficStore.entries.isEmpty)
                }
            }
            .alert("Clear Traffic", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    trafficStore.clearAllTraffic()
                }
            } message: {
                Text("Are you sure you want to clear all captured traffic?")
            }
            .sheet(item: $selectedEntry) { entry in
                TrafficDetailView(entry: entry)
            }
        }
        .onChange(of: selectedFilter) { _ in
            trafficStore.loadEntries(filter: selectedFilter, searchText: searchText)
        }
        .onChange(of: searchText) { _ in
            trafficStore.loadEntries(filter: selectedFilter, searchText: searchText)
        }
    }

    private var filteredEntries: [TrafficEntry] {
        var entries = trafficStore.entries

        // Apply filter
        if selectedFilter != .all {
            entries = entries.filter { selectedFilter.matches($0) }
        }

        // Apply search
        if !searchText.isEmpty {
            let lowercasedSearch = searchText.lowercased()
            entries = entries.filter {
                $0.url.lowercased().contains(lowercasedSearch) ||
                $0.host.lowercased().contains(lowercasedSearch) ||
                $0.path.lowercased().contains(lowercasedSearch)
            }
        }

        return entries
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: proxyConfig.localInspectionEnabled ? "network.slash" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(proxyConfig.localInspectionEnabled ? "No Traffic Captured" : "Local Inspection Disabled")
                .font(.headline)

            Text(proxyConfig.localInspectionEnabled ?
                 "Connect the VPN and browse to capture traffic" :
                 "Enable Local Traffic Inspection in Settings")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    TrafficListView()
        .environmentObject(TrafficStore.shared)
        .environmentObject(ProxyConfiguration.shared)
}
