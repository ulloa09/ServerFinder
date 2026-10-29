import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OpenWithSettingsView: View {
    let settings: OpenWithSettings

    @State private var newExtension = ""
    @State private var selection: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose the app for each file type")
                    .font(.title3.weight(.semibold))
                Text("Files you open from ServerFinder use the app chosen here. Other types open with the Mac's default app. Finder isn't affected.")
                    .foregroundStyle(.secondary)
            }

            List(selection: $selection) {
                ForEach(settings.rules.extensions, id: \.self) { fileExtension in
                    OpenWithRuleRow(settings: settings, fileExtension: fileExtension)
                        .tag(fileExtension)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if settings.rules.extensions.isEmpty {
                    Text("No rules yet: every file opens with the Mac's default app.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("File type, e.g. pdf", text: $newExtension)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove", action: removeSelected)
                    .disabled(selection == nil)
                Spacer()
            }

            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func add() {
        switch settings.addRule(for: newExtension) {
        case .added(let fileExtension):
            selection = fileExtension
            newExtension = ""
            notice = String(localized: "Pick the app for .\(fileExtension) from its menu.")
        case .needsApp(let fileExtension):
            if let app = AppChooser.chooseApp(forExtension: fileExtension) {
                settings.setApp(app, forExtension: fileExtension)
                selection = fileExtension
                newExtension = ""
                notice = nil
            }
        case .invalid:
            notice = String(localized: "Type just the file type, like pdf, docx or dwg.")
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        settings.removeRule(for: selection)
        self.selection = nil
        notice = nil
    }
}

private struct OpenWithRuleRow: View {
    let settings: OpenWithSettings
    let fileExtension: String

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: ".\(fileExtension)")
                .font(.body.monospaced())
                .frame(width: 90, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(OpenWithSettings.apps(forExtension: fileExtension), id: \.self) { app in
                    Button {
                        settings.setApp(app, forExtension: fileExtension)
                    } label: {
                        Label { Text(AppDisplay.name(of: app)) } icon: { Image(nsImage: AppDisplay.icon(of: app)) }
                    }
                }
                Divider()
                Button("Other…") {
                    if let app = AppChooser.chooseApp(forExtension: fileExtension) {
                        settings.setApp(app, forExtension: fileExtension)
                    }
                }
            } label: {
                if let app = settings.appURL(forExtension: fileExtension) {
                    Label { Text(AppDisplay.name(of: app)) } icon: { Image(nsImage: AppDisplay.icon(of: app)) }
                } else {
                    Label("App not found — using the Mac's default", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Lets the user pick any app from the Applications folder.
@MainActor
enum AppChooser {
    static func chooseApp(forExtension fileExtension: String) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the app that should open .\(fileExtension) files.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
