import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted after a fix is saved to the mistake log, so an open "My mistakes" window reloads (decision 0015).
    static let mistakeRecorded = Notification.Name("WritingAssistant.mistakeRecorded")
}

/// The rows shown in the "My mistakes" window, read from the same file the checker writes to.
@MainActor
final class MistakesModel: ObservableObject {
    enum View: String, CaseIterable { case all = "All fixes", repeated = "Most repeated" }

    @Published var view = View.all
    @Published var search = "" { didSet { reload() } }
    @Published var category: SuggestionCategory? { didSet { reload() } }
    /// Row ids (`MistakeEntry.id` is optional only before a row is saved).
    @Published var selection = Set<Int64?>()
    @Published private(set) var rows: [MistakeEntry] = []
    @Published private(set) var repeated: [RepeatedMistake] = []
    @Published private(set) var total = 0
    @Published private(set) var error: String?

    private let url: () -> URL
    private var log: MistakeLog?
    private var openURL: URL?

    init(url: @escaping () -> URL) { self.url = url }

    func reload() {
        do {
            let log = try current()
            rows = try log.recent(limit: 5000, category: category, search: search)
            repeated = try log.mostRepeated(limit: 100)
            total = try log.count()
            selection = selection.filter { id in rows.contains { $0.id == id } }
            error = nil
        } catch {
            self.log = nil
            self.error = "Can't read the mistake log: \(error)"
        }
    }

    func delete(_ ids: Set<Int64?>) {
        do {
            let log = try current()
            for id in ids.compactMap({ $0 }) { try log.delete(id: id) }
        } catch {
            self.error = "Can't delete: \(error)"
        }
        reload()
    }

    func exportCSV(to file: URL) throws {
        try Data(try current().exportCSV().utf8).write(to: file)
    }

    /// The debug socket can point the checker at a temp file; follow it.
    private func current() throws -> MistakeLog {
        let url = url()
        if let log, openURL == url { return log }
        let log = try MistakeLog(url: url)
        self.log = log
        openURL = url
        return log
    }
}

@MainActor
final class MistakesWindowController {
    static var shared: MistakesWindowController?

    let model: MistakesModel
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(url: @escaping () -> URL) {
        model = MistakesModel(url: url)
        observer = NotificationCenter.default.addObserver(forName: .mistakeRecorded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.model.reload()
            }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "My mistakes"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MistakesView(model: model, export: { [weak self] in self?.export() }))
            window.setFrameAutosaveName("MyMistakes")
            if !window.setFrameUsingName("MyMistakes") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "my-mistakes.csv"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try model.exportCSV(to: file)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    #if DEBUG
    var snapshotPNG: Data? { isVisible ? window?.contentView?.pngData() : nil }
    #endif
}

struct MistakesView: View {
    @ObservedObject var model: MistakesModel
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $model.view) {
                    ForEach(MistakesModel.View.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if model.view == .all {
                    Picker("Type", selection: $model.category) {
                        Text("All types").tag(SuggestionCategory?.none)
                        ForEach(SuggestionCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                    .fixedSize()
                    TextField("Search", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            switch model.view {
            case .all: allFixes
            case .repeated: mostRepeated
            }
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                if model.view == .all {
                    Button("Delete") { model.delete(model.selection) }
                        .disabled(model.selection.isEmpty)
                }
                Button("Export CSV…", action: export)
                    .disabled(model.total == 0)
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 300)
    }

    private var summary: String {
        switch model.view {
        case .all: model.rows.count == model.total ? "\(model.total) fixes" : "\(model.rows.count) of \(model.total) fixes"
        case .repeated: "\(model.repeated.count) different mistakes"
        }
    }

    private var allFixes: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("When") { Text($0.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 110, ideal: 130)
            TableColumn("App", value: \.appName).width(min: 60, ideal: 80)
            TableColumn("You wrote") { Text($0.original).foregroundStyle(.red) }.width(min: 80, ideal: 130)
            TableColumn("Changed to") { Text($0.replacement).foregroundStyle(.green) }.width(min: 80, ideal: 130)
            TableColumn("Type") { Text($0.category.rawValue.capitalized) }.width(min: 60, ideal: 80)
            TableColumn("Sentence") { Text($0.sentence).help($0.sentence) }
        }
        .contextMenu(forSelectionType: Int64?.self) { ids in
            Button("Delete") { model.delete(ids) }
        }
        .overlay {
            if model.rows.isEmpty {
                Text(model.total == 0 ? "No fixes saved yet. Accept a suggestion and it shows up here."
                                      : "Nothing matches.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mostRepeated: some View {
        Table(model.repeated) {
            TableColumn("Times") { Text("\($0.count)") }.width(min: 40, ideal: 50)
            TableColumn("You wrote") { Text($0.original).foregroundStyle(.red) }
            TableColumn("Changed to") { Text($0.replacement).foregroundStyle(.green) }
        }
    }
}

extension MistakeEntry: @retroactive Identifiable {}

extension RepeatedMistake: @retroactive Identifiable {
    public var id: String { original + "\u{1F}" + replacement }
}
