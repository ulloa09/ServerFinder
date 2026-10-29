import AppKit
import SwiftUI

struct FoldersSettingsView: View {
    let model: AppModel

    @State private var selection: IndexedFolder.ID?
    @State private var mountedServerVolumes: [URL] = []
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folders to search")
                    .font(.title3.weight(.semibold))
                Text("ServerFinder keeps a list of the file names in these folders on your Mac, so you can find any file instantly.")
                    .foregroundStyle(.secondary)
            }

            folderList

            HStack {
                Button {
                    chooseFolders()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button {
                    removeSelectedFolder()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                Spacer()
                Button {
                    model.rescanAll()
                } label: {
                    Label("Rescan Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.folders.isEmpty)
            }

            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !suggestedVolumes.isEmpty {
                suggestions
            }

            Spacer(minLength: 0)
            Divider()
            Label(
                "ServerFinder only reads file names. It never changes, moves or deletes anything on the server.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear(perform: refreshMountedVolumes)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshMountedVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshMountedVolumes()
        }
    }

    private var folderList: some View {
        List(selection: $selection) {
            ForEach(model.folders) { folder in
                FolderRow(model: model, folder: folder, isConnected: isConnected(folder))
                    .tag(folder.id)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 170)
        .onDeleteCommand(perform: removeSelectedFolder)
        .overlay {
            if model.folders.isEmpty {
                Text("No folders yet. Add a connected server folder below.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var suggestions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected server folders")
                            .font(.headline)
                        Text("These shared folders are connected right now. Add the ones you want to search.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if suggestedVolumes.count > 1 {
                        Button("Add All") {
                            for volume in suggestedVolumes { add(volume) }
                        }
                    }
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(suggestedVolumes, id: \.self) { volume in
                            HStack {
                                Image(systemName: "externaldrive.connected.to.line.below")
                                    .foregroundStyle(.secondary)
                                Text(FileManager.default.displayName(atPath: volume.path))
                                Spacer()
                                Button("Add") { add(volume) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    /// Mounted server volumes not already covered by an indexed folder.
    private var suggestedVolumes: [URL] {
        mountedServerVolumes.filter { volume in
            !model.folders.contains { $0.contains(path: volume.path) }
        }
    }

    private func isConnected(_ folder: IndexedFolder) -> Bool {
        guard folder.path.hasPrefix("/Volumes/") else { return true }
        return mountedServerVolumes.contains { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }
            || FileManager.default.fileExists(atPath: folder.path)
    }

    private func refreshMountedVolumes() {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        mountedServerVolumes = volumes
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func add(_ url: URL) {
        switch model.addFolder(at: url) {
        case .added:
            notice = nil
        case .alreadyIncluded(let folder):
            notice = String(localized: "“\(url.lastPathComponent)” is already searched as part of “\(folder.name)”.")
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the server folders you want to search.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    private func removeSelectedFolder() {
        guard let folder = model.folders.first(where: { $0.id == selection }) else { return }
        model.removeFolder(folder)
        selection = nil
    }
}

private struct FolderRow: View {
    let model: AppModel
    let folder: IndexedFolder
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isConnected ? "folder.fill" : "folder")
                .font(.title2)
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .fontWeight(.medium)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            status
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }

    /// Lists the skipped folders when hovering the warning.
    private func unreadableHelp(_ paths: [String]) -> String {
        let shown = paths.prefix(15).map { "• \($0)" }
        let more = paths.count > 15 ? ["…"] : []
        let intro = String(localized: "You don't have permission to open these folders, so their files aren't searchable:")
        return ([intro] + shown + more).joined(separator: "\n")
    }

    @ViewBuilder
    private var status: some View {
        if let scan = model.currentScan, scan.folderID == folder.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Indexing… \(scan.found.formatted()) found")
            }
        } else if model.isQueued(folder) {
            Text("Waiting to index…")
                .foregroundStyle(.secondary)
        } else if let error = model.scanErrors[folder.id] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(maxWidth: 240, alignment: .trailing)
        } else if let lastIndexed = folder.lastIndexedAt {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\((model.itemCounts[folder.id] ?? 0).formatted()) items")
                Text("Updated \(lastIndexed.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
                if let unreadable = model.unreadableFolders[folder.id] {
                    Label("\(unreadable.count) folders couldn't be read", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                        .help(unreadableHelp(unreadable))
                }
            }
        } else {
            Text("Not indexed yet")
                .foregroundStyle(.secondary)
        }
        if !isConnected {
            Text("Not connected")
                .foregroundStyle(.secondary)
        }
    }
}
