import AkaMemoCore
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let diagnostics: AppDiagnostics?

    @State private var entries: [LogEntry] = []
    @State private var paused = false
    @State private var levelFilter: LogLevel?
    @State private var categoryFilter: LogCategory?
    @State private var sourceFilter: LogSource?
    @State private var searchText = ""
    @State private var debugEnabled = false
    @State private var droppedCount = 0
    @State private var activeAlert: DiagnosticsAlert?
    @State private var exportDocument: DiagnosticsExportDocument?
    @State private var exportFileName = "AkaMemo-diagnostics.jsonl"
    @State private var isExporting = false

    private enum DiagnosticsAlert: String, Identifiable {
        case clear
        case export

        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if diagnostics == nil {
                ContentUnavailableView(
                    "diagnostics.unavailable.title",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("diagnostics.unavailable.message")
                )
            } else {
                content
            }
        }
        .navigationTitle("diagnostics.title")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    paused.toggle()
                    if !paused {
                        Task { await refreshFromStore() }
                    }
                } label: {
                    Image(
                        systemName: paused ? "play.circle" : "pause.circle"
                    )
                }
                .accessibilityLabel(
                    Text(
                        LocalizedStringKey(
                            paused ? "diagnostics.resume" : "diagnostics.pause"
                        )
                    )
                )

                Button {
                    activeAlert = .export
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("diagnostics.export"))

                Button(role: .destructive) {
                    activeAlert = .clear
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("diagnostics.clear"))
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("diagnostics.search.prompt")
        )
        .task {
            await subscribe()
        }
        .onChange(of: debugEnabled) { _, enabled in
            Task {
                await diagnostics?.setDebugEnabled(enabled)
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .clear:
                Alert(
                    title: Text("diagnostics.clear.confirm.title"),
                    message: Text("diagnostics.clear.confirm.message"),
                    primaryButton: .destructive(Text("diagnostics.clear")) {
                        Task {
                            await clearLogs()
                        }
                    },
                    secondaryButton: .cancel(Text("deletion.cancel"))
                )
            case .export:
                Alert(
                    title: Text("diagnostics.export.warning.title"),
                    message: Text("diagnostics.export.warning.message"),
                    primaryButton: .default(Text("diagnostics.export.continue")) {
                        Task {
                            await prepareExport()
                        }
                    },
                    secondaryButton: .cancel(Text("deletion.cancel"))
                )
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFileName
        ) { _ in
            exportDocument = nil
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            if paused {
                Text("diagnostics.paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
            ScrollViewReader { proxy in
                List {
                    if droppedCount > 0 {
                        HStack {
                            Text("diagnostics.dropped")
                            Text("\(droppedCount)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(filteredEntries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
                .onChange(of: filteredEntries.last?.id) { _, id in
                    guard let id else {
                        return
                    }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Menu {
                    Button("diagnostics.filter.all") {
                        levelFilter = nil
                    }
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Button(levelLabel(level)) {
                            levelFilter = level
                        }
                    }
                } label: {
                    Label(
                        levelFilter.map(levelLabel)
                            ?? String(localized: "diagnostics.filter.all"),
                        systemImage: "exclamationmark.triangle"
                    )
                }
                Menu {
                    Button("diagnostics.filter.all") {
                        categoryFilter = nil
                    }
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Button(categoryLabel(category)) {
                            categoryFilter = category
                        }
                    }
                } label: {
                    Label(
                        categoryFilter.map(categoryLabel)
                            ?? String(localized: "diagnostics.filter.all"),
                        systemImage: "square.grid.2x2"
                    )
                }
                Menu {
                    Button("diagnostics.filter.all") {
                        sourceFilter = nil
                    }
                    ForEach(LogSource.allCases, id: \.self) { source in
                        Button(sourceLabel(source)) {
                            sourceFilter = source
                        }
                    }
                } label: {
                    Label(
                        sourceFilter.map(sourceLabel)
                            ?? String(localized: "diagnostics.filter.all"),
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
            }
            .font(.caption)
            Toggle("diagnostics.debug", isOn: $debugEnabled)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let levelFilter, entry.level != levelFilter {
                return false
            }
            if let categoryFilter, entry.category != categoryFilter {
                return false
            }
            if let sourceFilter, entry.source != sourceFilter {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            if entry.message.localizedCaseInsensitiveContains(query) {
                return true
            }
            return entry.metadata.values.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private func subscribe() async {
        guard let diagnostics else {
            return
        }
        await refreshFromStore()
        debugEnabled = await diagnostics.isDebugEnabled()
        for await entry in await diagnostics.stream() {
            if Task.isCancelled {
                break
            }
            if paused {
                continue
            }
            entries.append(entry)
            if entries.count > 2_000 {
                entries.removeFirst(entries.count - 2_000)
            }
            droppedCount = await diagnostics.droppedCount()
        }
    }

    private func refreshFromStore() async {
        guard let diagnostics else {
            return
        }
        entries = await diagnostics.snapshot()
        droppedCount = await diagnostics.droppedCount()
    }

    private func clearLogs() async {
        await diagnostics?.clear()
        entries = []
        droppedCount = 0
    }

    private func prepareExport() async {
        guard let diagnostics else {
            return
        }
        let text = await diagnostics.exportJSONL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        exportFileName =
            "AkaMemo-diagnostics-\(formatter.string(from: Date())).jsonl"
        exportDocument = DiagnosticsExportDocument(text: text)
        isExporting = true
    }

    private func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .debug: String(localized: "diagnostics.level.debug")
        case .info: String(localized: "diagnostics.level.info")
        case .warning: String(localized: "diagnostics.level.warning")
        case .error: String(localized: "diagnostics.level.error")
        }
    }

    private func categoryLabel(_ category: LogCategory) -> String {
        NSLocalizedString("diagnostics.category.\(category.rawValue)", comment: "")
    }

    private func sourceLabel(_ source: LogSource) -> String {
        NSLocalizedString("diagnostics.source.\(source.rawValue)", comment: "")
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(
                    entry.timestamp,
                    format: .dateTime.hour().minute().second()
                )
                Text(entry.level.rawValue.uppercased())
                Text(entry.category.rawValue)
                Spacer()
                Text(entry.source.rawValue)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(entry.message)
                .font(.caption.monospaced())

            if !entry.metadata.isEmpty {
                Text(
                    entry.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DiagnosticsExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
            let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
