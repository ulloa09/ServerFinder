import SwiftUI

struct ExclusionsSettingsView: View {
    let model: AppModel

    /// Shows the "rescan to apply" hint after an edit.
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PatternListEditor(
                title: "Leave out of the search",
                explanation: "Files and folders with these names aren't indexed at all. Excluded folders aren't even opened, which also makes scans faster.",
                patterns: model.exclusions.patterns,
                placeholder: "Name or pattern, e.g. *.tmp",
                restoreTitle: "Restore Windows Defaults",
                onChange: {
                    model.setExclusionPatterns($0)
                    hasChanges = true
                },
                onRestore: {
                    model.restoreDefaultExclusions()
                    hasChanges = true
                }
            )

            if hasChanges {
                HStack {
                    Label("Changes apply the next time folders are indexed.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan Now") {
                        model.rescanAll()
                        hasChanges = false
                    }
                    .disabled(model.folders.isEmpty)
                }
            }

            Divider()

            PatternListEditor(
                title: "Never read the contents of",
                explanation: "Files with these names, and everything inside folders with these names, are still found by name, but ServerFinder never reads or stores what's inside them. Use it for passwords or other private data. Changes apply right away.",
                patterns: model.neverRead.patterns,
                placeholder: "Name or pattern, e.g. *contraseña*",
                restoreTitle: "Restore Defaults",
                onChange: { model.setNeverReadPatterns($0) },
                onRestore: { model.restoreDefaultNeverRead() }
            )

            Text("* means any text, ? one character. Capitals don't matter. A pattern with / (e.g. Backups/Old) means a folder inside a shared folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

/// A list of name patterns with add, remove and restore-defaults.
private struct PatternListEditor: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    let patterns: [String]
    let placeholder: LocalizedStringKey
    let restoreTitle: LocalizedStringKey
    let onChange: ([String]) -> Void
    let onRestore: () -> Void

    @State private var newPattern = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(patterns, id: \.self) { pattern in
                    Text(pattern)
                        .font(.body.monospaced())
                        .tag(pattern)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 90, maxHeight: 130)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if patterns.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField(placeholder, text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove", action: removeSelected)
                    .disabled(selection == nil)
                Button(restoreTitle, action: onRestore)
            }
        }
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        onChange(patterns + [pattern])
        newPattern = ""
    }

    private func removeSelected() {
        guard let selection else { return }
        onChange(patterns.filter { $0 != selection })
        self.selection = nil
    }
}
