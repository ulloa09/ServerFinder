import ServerFinderCore
import SwiftUI

struct ContentSettingsView: View {
    let model: AppModel

    @State private var isConfirmingErase = false

    private var settings: ContentSettings { model.contentSettings }

    var body: some View {
        Form {
            Section {
                Toggle("Search inside documents", isOn: binding(\.isEnabled))
            } footer: {
                Text("ServerFinder reads the text of documents in the background after each scan and keeps it on this Mac. Turning this off stops reading and hides the Inside files tab; what was read is kept until you erase it.")
                    .foregroundStyle(.secondary)
            }

            Section("File types") {
                ForEach(DocumentKind.allCases, id: \.self) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title)
                            Text(kind.extensions.sorted().map { ".\($0)" }.joined(separator: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: binding(\.recognizesScans)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recognize text in scanned PDFs and images")
                        Text("About a third of a second per page, up to 100 pages per document. Spanish and English. Runs after everything else, and pauses in Low Power Mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(settings.kinds.isDisjoint(with: ContentSettings.recognizedKinds))
                Picker("Largest file to read", selection: binding(\.maxSizeMB)) {
                    ForEach(ContentSettings.sizeChoicesMB, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
            }
            .disabled(!settings.isEnabled)

            Section("Progress") {
                progress
            }

            Section {
                if isConfirmingErase {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Erase the stored text of all documents from this Mac? File names stay searchable. If content search is on, documents are read again from the start.")
                        HStack {
                            Spacer()
                            Button("Cancel") { isConfirmingErase = false }
                            Button("Erase", role: .destructive) {
                                model.eraseAllContents()
                                isConfirmingErase = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                } else {
                    Button("Erase Stored Document Text…", role: .destructive) { isConfirmingErase = true }
                }
            } footer: {
                Text("Files you list under Excluded → Never read the contents of are never read.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshContentCounts() }
    }

    @ViewBuilder
    private var progress: some View {
        let totals = model.totalContentCounts
        if let reading = model.contentProgress, reading.total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.contentStatusText ?? "")
                ProgressView(value: Double(reading.done), total: Double(reading.total))
            }
        } else if !settings.isEnabled {
            Text("Content search is off.")
                .foregroundStyle(.secondary)
        } else if totals.isEmpty {
            Text("No documents read yet. Reading starts after the next scan.")
                .foregroundStyle(.secondary)
        } else {
            Text("All documents are up to date.")
        }
        if !totals.isEmpty {
            LabeledContent("Searchable documents", value: totals.searchable.formatted())
            LabeledContent("Without text", value: (totals[.noText] ?? 0).formatted())
            LabeledContent("Scans and images recognized", value: (totals[.recognized] ?? 0).formatted())
            LabeledContent(
                settings.readsScans ? "Scans and images waiting for recognition" : "Scans and images not recognized",
                value: (totals[.needsOCR] ?? 0).formatted()
            )
            LabeledContent("Couldn't be read", value: (totals[.failed] ?? 0).formatted())
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ContentSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.contentSettings[keyPath: keyPath] },
            set: { value in model.updateContentSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func kindBinding(_ kind: DocumentKind) -> Binding<Bool> {
        Binding(
            get: { model.contentSettings.kinds.contains(kind) },
            set: { isOn in
                model.updateContentSettings { settings in
                    if isOn { settings.kinds.insert(kind) } else { settings.kinds.remove(kind) }
                }
            }
        )
    }
}

extension DocumentKind {
    var title: LocalizedStringKey {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        case .powerPoint: "PowerPoint"
        case .excel: "Excel"
        case .text: "Text, CSV and RTF"
        case .xml: "XML"
        case .image: "Images"
        }
    }
}
