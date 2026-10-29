import SwiftUI

struct ExclusionsSettingsView: View {
    let model: AppModel

    @State private var newPattern = ""
    @State private var selection: String?
    /// Shows the "rescan to apply" hint after an edit.
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Leave out of the search")
                    .font(.title3.weight(.semibold))
                Text("Files and folders with these names aren't indexed. Excluded folders aren't even opened, which also makes scans faster.")
                    .foregroundStyle(.secondary)
            }

            List(selection: $selection) {
                ForEach(model.exclusions.patterns, id: \.self) { pattern in
                    Text(pattern)
                        .font(.body.monospaced())
                        .tag(pattern)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if model.exclusions.patterns.isEmpty {
                    Text("Nothing is excluded.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("Name or pattern, e.g. *.tmp", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove", action: removeSelected)
                    .disabled(selection == nil)
            }

            Text("Examples: Thumbs.db · ~$* (Office temporary files) · *.tmp · Backups/Old (a folder inside a shared folder). * means any text, ? one character. Capitals don't matter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Restore Windows Defaults") {
                    model.restoreDefaultExclusions()
                    hasChanges = true
                }
                Spacer()
            }

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

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        model.setExclusionPatterns(model.exclusions.patterns + [pattern])
        newPattern = ""
        hasChanges = true
    }

    private func removeSelected() {
        guard let selection else { return }
        model.setExclusionPatterns(model.exclusions.patterns.filter { $0 != selection })
        self.selection = nil
        hasChanges = true
    }
}
