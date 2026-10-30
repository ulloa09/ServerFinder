import AppKit
import ServerFinderCore
import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    let controller: SearchController
    let general: GeneralSettings
    let onOpenSettings: () -> Void
    let onDidOpen: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    private var model: AppModel { controller.model }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let notice = controller.notice {
                NoticeBanner(text: notice)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 440)
        .onChange(of: controller.focusRequest) { isSearchFieldFocused = true }
        .onChange(of: model.indexVersion) { controller.refresh() }
        .onAppear { isSearchFieldFocused = true }
    }

    private var searchField: some View {
        @Bindable var controller = controller
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField("Search files on the server", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($isSearchFieldFocused)
            if !controller.query.isEmpty {
                Button {
                    controller.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if model.folders.isEmpty {
            EmptyStateView(
                systemImage: "externaldrive.badge.plus",
                title: "Choose what to search",
                message: "Pick the server folders ServerFinder should index. You only need to do this once.",
                buttonTitle: "Choose Folders…",
                action: onOpenSettings
            )
        } else if controller.trimmedQuery.isEmpty {
            VStack(spacing: 0) {
                EmptyStateView(
                    systemImage: "text.magnifyingglass",
                    title: "Type part of a file name",
                    message: "For example “invoice”, “acme 2024” or “plan .pdf” to see only PDFs. Press Return to open the selected file."
                )
                if let shortcut = general.searchShortcut {
                    Text("Tip: press \(shortcut.displayString) in any app to open this search.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else if controller.results.isEmpty && controller.contentResults.isEmpty && controller.hasResults {
            EmptyStateView(
                systemImage: "questionmark.folder",
                title: "No matches for “\(controller.trimmedQuery)”",
                message: model.currentScan == nil && model.contentProgress == nil
                    ? "Try fewer letters or a different part of the name."
                    : "Still indexing — more results may appear in a moment."
            )
        } else {
            VStack(spacing: 0) {
                if controller.hasResults && model.contentSettings.isEnabled {
                    ResultsTabBar(controller: controller, isReadingDocuments: model.contentProgress != nil)
                }
                if controller.visibleResults.isEmpty && controller.hasResults {
                    emptyTabMessage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultsList(controller: controller, onDidOpen: onDidOpen)
                }
            }
        }
    }

    /// One tab is empty while the other has results.
    @ViewBuilder
    private var emptyTabMessage: some View {
        if controller.tab == .names {
            EmptyStateView(
                systemImage: "doc.text.magnifyingglass",
                title: "No names match",
                message: "\(controller.contentResults.count) documents contain these words. Press Tab to see them."
            )
        } else if let reading = model.contentProgress, reading.total > 0 {
            EmptyStateView(
                systemImage: "hourglass",
                title: "No documents contain these words yet",
                message: "Still reading documents (\(reading.done.formatted()) of \(reading.total.formatted())). More matches may appear."
            )
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: "No documents contain these words",
                message: "Inside documents, words match from their beginning. Press Tab to go back to name results."
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let confirmation = controller.confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                if model.currentScan != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if controller.selectedHit != nil {
                Text("↩ Open   ␣ Preview   ⌘↩ Show in Finder   ⌘C Copy Path")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Button {
                model.rescanAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.folders.isEmpty)
            .help("Rescan all folders now")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ResultsList: View {
    let controller: SearchController
    let onDidOpen: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.visibleResults.enumerated()), id: \.element.id) { index, hit in
                        row(hit, at: index)
                    }
                }
                .padding(6)
            }
            .id(controller.tab) // start at the top when switching tabs
            .onChange(of: controller.selectedIndex) {
                guard let hit = controller.selectedHit else { return }
                proxy.scrollTo(hit.id)
            }
        }
    }

    private func row(_ hit: SearchHit, at index: Int) -> some View {
        ResultRow(
            hit: hit,
            terms: controller.searchTerms,
            isSelected: index == controller.selectedIndex
        )
        .id(hit.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            controller.selectedIndex = index
            if controller.open(hit) { onDidOpen() }
        }
        .simultaneousGesture(TapGesture().onEnded { controller.selectedIndex = index })
        // Drag a result into Mail, Finder or any app that accepts files.
        .onDrag { NSItemProvider(contentsOf: hit.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") {
                if controller.open(hit) { onDidOpen() }
            }
            Button("Show in Finder") {
                if controller.revealInFinder(hit) { onDidOpen() }
            }
            Divider()
            Button("Copy Path") { controller.copyPath(hit) }
        }
    }
}

/// "Names (12) | Inside files (3)". Tab switches between them.
private struct ResultsTabBar: View {
    let controller: SearchController
    let isReadingDocuments: Bool

    var body: some View {
        @Bindable var controller = controller
        return HStack(spacing: 10) {
            Picker("", selection: $controller.tab) {
                Text("Names (\(Self.count(controller.results.count, limit: 200)))")
                    .tag(SearchController.ResultsTab.names)
                Text("Inside files (\(Self.count(controller.contentResults.count, limit: 50)))")
                    .tag(SearchController.ResultsTab.contents)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if isReadingDocuments {
                ProgressView()
                    .controlSize(.mini)
                    .help("Still reading documents: more matches inside files may appear.")
            }
            Spacer()
            Text("⇥ Tab to switch")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Results are capped; show "200+" rather than a misleading exact count.
    private static func count(_ value: Int, limit: Int) -> String {
        value >= limit ? "\(limit)+" : "\(value)"
    }
}

private struct ResultRow: View {
    let hit: SearchHit
    let terms: [String]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: hit))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.location)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let snippet = hit.snippet {
                    Text(Self.highlighted(snippet))
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.8)))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let modified = hit.result.modifiedAt {
                    Text(ResultFormat.date(modified))
                }
                if !hit.isDirectory {
                    Text(hit.result.size.formatted(.byteCount(style: .file)))
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .help(hit.url.path)
    }

    /// A content preview with the matched words (between the snippet markers) in bold.
    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isMatch = false
        var current = ""
        func flush() {
            var part = AttributedString(current)
            if isMatch { part.font = .caption.bold() }
            result += part
            current = ""
        }
        for character in snippet {
            switch character {
            case ContentResult.highlightStart: flush(); isMatch = true
            case ContentResult.highlightEnd: flush(); isMatch = false
            default: current.append(character)
            }
        }
        flush()
        return result
    }

    /// The name with the searched words in bold.
    private var highlightedName: AttributedString {
        var name = AttributedString(hit.name)
        for term in terms {
            if let range = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                name[range].font = .body.bold()
            }
        }
        return name
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .symbolRenderingMode(.multicolor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.15))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var buttonTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding()
    }
}

enum ResultFormat {
    /// Today: the time. This year: day and month. Older: with the year.
    static func date(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// File-type icons. Looked up by extension so no request goes to the server.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for hit: SearchHit) -> NSImage {
        let key = hit.isDirectory ? "/folder" : (hit.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = hit.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}
