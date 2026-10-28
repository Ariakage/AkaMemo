import AkaMemoCore
import SwiftUI

struct SearchView: View {
    let search: SearchCoordinator?
    let transcription: TranscriptionCoordinator?
    let deletion: DeletionCoordinator?

    @State private var query = ""
    @State private var timeRange: SearchTimeRange = .all
    @State private var sort: SearchSort = .relevance
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    private struct Request: Hashable {
        let query: String
        let range: SearchTimeRange
        let sort: SearchSort
    }

    private var request: Request {
        Request(query: query, range: timeRange, sort: sort)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if search?.isAvailable != true || search?.indexUnavailable == true {
                ContentUnavailableView(
                    "search.unavailable.title",
                    systemImage: "magnifyingglass",
                    description: Text("search.unavailable.message")
                )
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView(
                    "search.idle.title",
                    systemImage: "magnifyingglass",
                    description: Text("search.idle.message")
                )
            } else if hasSearched && hits.isEmpty && !isSearching {
                ContentUnavailableView(
                    "search.empty.title",
                    systemImage: "magnifyingglass",
                    description: Text("search.empty.message")
                )
            } else {
                resultsList
            }
        }
        .navigationTitle("search.title")
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("search.prompt")
        )
        .toolbar { filterMenu }
        .task(id: request) {
            await performSearch()
        }
    }

    private var resultsList: some View {
        List {
            if isSearching {
                HStack {
                    ProgressView()
                    Text("search.searching")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        NavigationLink {
                            SessionDetailView(
                                sessionID: hit.sessionID,
                                transcription: transcription,
                                deletion: deletion,
                                startChunkID: hit.chunkID,
                                startAtMs: hit.startMs
                            )
                        } label: {
                            SearchResultRow(hit: hit, query: trimmedQuery)
                        }
                    }
                } header: {
                    Text(
                        group.day,
                        format: .dateTime.year().month().day()
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("search.filter.time", selection: $timeRange) {
                    ForEach(SearchTimeRange.allCases) { option in
                        Text(option.titleKey).tag(option)
                    }
                }
                Picker("search.filter.sort", selection: $sort) {
                    Text("search.sort.relevance")
                        .tag(SearchSort.relevance)
                    Text("search.sort.newest")
                        .tag(SearchSort.newest)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(Text("search.filter.title"))
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let hits: [SearchHit]

        var id: Date { day }
    }

    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: hits) { hit in
            calendar.startOfDay(for: TimeMath.date(epochMs: hit.startMs))
        }
        return
            grouped
            .map { day, dayHits in
                DayGroup(
                    day: day,
                    hits: dayHits.sorted { $0.startMs > $1.startMs }
                )
            }
            .sorted { $0.day > $1.day }
    }

    private func performSearch() async {
        guard !trimmedQuery.isEmpty else {
            hits = []
            hasSearched = false
            isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled {
            return
        }
        let bounds = timeRange.bounds()
        let results =
            await search?.search(
                SearchQuery(
                    text: trimmedQuery,
                    limit: 100,
                    startMs: bounds.startMs,
                    endMs: bounds.endMs,
                    sort: sort
                )
            ) ?? []
        if Task.isCancelled {
            return
        }
        hits = results
        hasSearched = true
    }
}

enum SearchTimeRange: String, CaseIterable, Identifiable, Hashable {
    case all
    case today
    case yesterday
    case week

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all: "search.range.all"
        case .today: "search.range.today"
        case .yesterday: "search.range.yesterday"
        case .week: "search.range.week"
        }
    }

    func bounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (startMs: Int64?, endMs: Int64?) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .all:
            return (nil, nil)
        case .today:
            return (TimeMath.epochMs(startOfToday), nil)
        case .yesterday:
            let start =
                calendar.date(
                    byAdding: .day,
                    value: -1,
                    to: startOfToday
                ) ?? startOfToday
            return (TimeMath.epochMs(start), TimeMath.epochMs(startOfToday))
        case .week:
            let start =
                calendar.date(
                    byAdding: .day,
                    value: -6,
                    to: startOfToday
                ) ?? startOfToday
            return (TimeMath.epochMs(start), nil)
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlighted(hit.snippet, query: query))
                .font(.subheadline)
                .lineLimit(3)
            Text(
                TimeMath.date(epochMs: hit.startMs),
                format: .dateTime.hour().minute().second()
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("search.openHint"))
    }

    private func highlighted(
        _ text: String,
        query: String
    ) -> AttributedString {
        let terms = SearchText.terms(query)
        guard !terms.isEmpty else {
            return AttributedString(text)
        }
        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex {
            var best: Range<String.Index>?
            for term in terms {
                guard
                    let range = text.range(
                        of: term,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: cursor..<text.endIndex
                    )
                else {
                    continue
                }
                if let current = best {
                    if range.lowerBound < current.lowerBound {
                        best = range
                    }
                } else {
                    best = range
                }
            }
            guard let match = best else {
                result += AttributedString(String(text[cursor...]))
                break
            }
            result += AttributedString(String(text[cursor..<match.lowerBound]))
            var highlighted = AttributedString(String(text[match]))
            highlighted.backgroundColor = .yellow.opacity(0.35)
            highlighted.font = .body.bold()
            result += highlighted
            cursor = match.upperBound
        }
        return result
    }
}
