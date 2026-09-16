import SwiftUI
import AppKit
import UniformTypeIdentifiers

let MTP_ROOT: UInt32 = 0xFFFF_FFFF
let AMAZON_VID: UInt16 = 0x1949

// Extensions we open in the built-in editor. Everything else is download/upload only.
let TEXT_EXTS: Set<String> = ["txt", "md", "json", "xml", "csv", "log", "opf", "html",
                              "htm", "ini", "cfg", "conf", "yaml", "yml", "srt", "nfo"]
let EDIT_SIZE_LIMIT: UInt64 = 8 << 20

// MARK: - Model

struct Entry: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let size: UInt64
    let isFolder: Bool
    let modified: Date?
}

struct Storage: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let free: UInt64
    let total: UInt64
}

struct EditSession: Identifiable {
    let id: UInt32
    let name: String
    let parent: UInt32
    let storage: UInt32
    let hadBOM: Bool
    var text: String
}

struct MTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - libmtp engine
//
// libmtp is not thread-safe and holds one USB claim, so every call below runs on
// MTPEngine.queue and nowhere else.

private var gProgress: ((UInt64, UInt64) -> Void)?

private let progressCB: LIBMTP_progressfunc_t = { sent, total, _ in
    gProgress?(sent, total)
    return 0
}

final class MTPEngine {
    static let shared = MTPEngine()
    static let queue = DispatchQueue(label: "mtp.serial")

    private var dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var didInit = false

    // MARK: connection

    func connect() throws -> (name: String, storages: [Storage]) {
        if !didInit { LIBMTP_Init(); didInit = true }
        disconnect()

        var rawList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&rawList, &count)
        guard err == LIBMTP_ERROR_NONE, let raws = rawList, count > 0 else {
            if let r = rawList { free(r) }
            throw MTPError(message: "No MTP device found. Plug in the Kindle and unlock the screen.")
        }
        defer { free(raws) }

        // Prefer an Amazon device when several are attached.
        var pick = 0
        for i in 0..<Int(count) where raws[i].device_entry.vendor_id == AMAZON_VID {
            pick = i
            break
        }

        guard let opened = LIBMTP_Open_Raw_Device_Uncached(raws.advanced(by: pick)) else {
            throw MTPError(message: "Found a device but could not claim it. Unplug/replug, and close Image Capture or Android File Transfer if either grabbed it.")
        }
        dev = opened

        var name = cstr(raws[pick].device_entry.product) ?? "MTP device"
        if let friendly = LIBMTP_Get_Friendlyname(opened) {
            let s = String(cString: friendly)
            free(friendly)
            if !s.isEmpty { name = s }
        } else if let model = LIBMTP_Get_Modelname(opened) {
            let s = String(cString: model)
            free(model)
            if !s.isEmpty { name = s }
        }

        LIBMTP_Get_Storage(opened, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))
        var storages: [Storage] = []
        var node = opened.pointee.storage
        while let n = node {
            storages.append(Storage(id: n.pointee.id,
                                    name: cstr(n.pointee.StorageDescription) ?? "Storage",
                                    free: n.pointee.FreeSpaceInBytes,
                                    total: n.pointee.MaxCapacity))
            node = n.pointee.next
        }
        guard !storages.isEmpty else {
            throw MTPError(message: "\(name) exposed no storage. Unlock the Kindle and try again.")
        }
        return (name, storages)
    }

    func disconnect() {
        if let d = dev { LIBMTP_Release_Device(d) }
        dev = nil
    }

    // MARK: operations

    func list(storage: UInt32, parent: UInt32) throws -> [Entry] {
        let d = try device()
        LIBMTP_Clear_Errorstack(d)   // an empty folder is detected via the errorstack below
        var out: [Entry] = []
        var node = LIBMTP_Get_Files_And_Folders(d, storage, parent)
        while let n = node {
            let next = n.pointee.next
            out.append(Entry(id: n.pointee.item_id,
                             name: cstr(n.pointee.filename) ?? "(unnamed)",
                             size: n.pointee.filesize,
                             isFolder: n.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
                             modified: n.pointee.modificationdate > 0
                                 ? Date(timeIntervalSince1970: TimeInterval(n.pointee.modificationdate)) : nil))
            LIBMTP_destroy_file_t(n)
            node = next
        }
        // A NULL list is also how an empty folder looks, so only an errorstack entry is a real failure.
        if out.isEmpty, let e = drainErrors() { throw MTPError(message: e) }
        return out.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func download(id: UInt32, to url: URL) throws {
        let d = try device()
        if LIBMTP_Get_File_To_File(d, id, url.path, progressCB, nil) != 0 {
            throw MTPError(message: drainErrors() ?? "Download failed.")
        }
    }

    /// Returns the new object's item id.
    @discardableResult
    func upload(_ url: URL, name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let d = try device()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        guard let meta = LIBMTP_new_file_t() else { throw MTPError(message: "Out of memory.") }
        defer { LIBMTP_destroy_file_t(meta) }   // frees meta.filename too
        meta.pointee.filename = strdup(name)
        meta.pointee.filesize = size
        meta.pointee.parent_id = parent
        meta.pointee.storage_id = storage
        meta.pointee.filetype = mtpType(url.pathExtension)

        if LIBMTP_Send_File_From_File(d, url.path, meta, progressCB, nil) != 0 {
            throw MTPError(message: drainErrors() ?? "Upload of \(name) failed.")
        }
        return meta.pointee.item_id
    }

    func delete(id: UInt32) throws {
        let d = try device()
        if LIBMTP_Delete_Object(d, id) != 0 {
            throw MTPError(message: drainErrors() ?? "Delete failed.")
        }
    }

    func createFolder(name: String, storage: UInt32, parent: UInt32) throws {
        let d = try device()
        var buf = Array(name.utf8CString)
        let newID = buf.withUnsafeMutableBufferPointer {
            LIBMTP_Create_Folder(d, $0.baseAddress, parent, storage)
        }
        if newID == 0 { throw MTPError(message: drainErrors() ?? "Could not create folder.") }
    }

    /// Send-then-delete: if the send fails the original is still on the device.
    func replace(old: UInt32, with url: URL, name: String, storage: UInt32, parent: UInt32) throws {
        try upload(url, name: name, storage: storage, parent: parent)
        try delete(id: old)
    }

    // MARK: helpers

    private func device() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let d = dev else { throw MTPError(message: "Not connected.") }
        return d
    }

    private func drainErrors() -> String? {
        guard let d = dev else { return nil }
        var msgs: [String] = []
        var node = LIBMTP_Get_Errorstack(d)
        while let n = node {
            if let t = n.pointee.error_text { msgs.append(String(cString: t)) }
            node = n.pointee.next
        }
        LIBMTP_Clear_Errorstack(d)
        return msgs.isEmpty ? nil : msgs.joined(separator: " / ")
    }

    private func cstr(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p = p else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    private func mtpType(_ ext: String) -> LIBMTP_filetype_t {
        // Kindle book formats (azw3/epub/mobi/pdf) have no MTP type; UNKNOWN is what
        // mtp-tools sends for them and the device indexes them fine.
        switch ext.lowercased() {
        case "txt", "md", "log", "csv": return LIBMTP_FILETYPE_TEXT
        case "html", "htm":             return LIBMTP_FILETYPE_HTML
        case "xml", "opf":              return LIBMTP_FILETYPE_XML
        case "jpg", "jpeg":             return LIBMTP_FILETYPE_JPEG
        case "png":                     return LIBMTP_FILETYPE_PNG
        case "gif":                     return LIBMTP_FILETYPE_GIF
        case "mp3":                     return LIBMTP_FILETYPE_MP3
        default:                        return LIBMTP_FILETYPE_UNKNOWN
        }
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var deviceName = ""
    @Published var storages: [Storage] = []
    @Published var storageID: UInt32 = 0
    @Published var crumbs: [Entry] = []          // folder chain below the storage root
    @Published var entries: [Entry] = []
    @Published var selection: Set<UInt32> = []
    @Published var status = "Not connected"
    @Published var busy = false
    @Published var progress: Double?
    @Published var editing: EditSession?
    @Published var connected = false

    var parentID: UInt32 { crumbs.last?.id ?? MTP_ROOT }
    var currentStorage: Storage? { storages.first { $0.id == storageID } }

    // MARK: plumbing

    private func run<T>(_ label: String,
                        _ work: @escaping () throws -> T,
                        then finish: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        progress = nil
        status = label
        MTPEngine.queue.async {
            gProgress = { sent, total in
                let p = total > 0 ? Double(sent) / Double(total) : 0
                DispatchQueue.main.async { self.progress = p }
            }
            defer { gProgress = nil }
            do {
                let value = try work()
                DispatchQueue.main.async {
                    self.busy = false
                    self.progress = nil
                    self.status = "Ready"
                    finish(value)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.progress = nil
                    self.status = error.localizedDescription
                }
            }
        }
    }

    // MARK: actions

    func connect() {
        run("Connecting…", { try MTPEngine.shared.connect() }) { result in
            self.deviceName = result.name
            self.storages = result.storages
            self.storageID = result.storages[0].id
            self.crumbs = []
            self.connected = true
            self.refresh()
        }
    }

    func refresh() {
        let storage = storageID, parent = parentID
        run("Loading…", { try MTPEngine.shared.list(storage: storage, parent: parent) }) {
            self.entries = $0
            self.selection = []
        }
    }

    func open(_ entry: Entry) {
        if entry.isFolder {
            crumbs.append(entry)
            refresh()
        } else if TEXT_EXTS.contains(entry.name.pathExtensionLower), entry.size <= EDIT_SIZE_LIMIT {
            edit(entry)
        } else {
            download([entry])
        }
    }

    func navigate(toDepth depth: Int) {
        guard depth < crumbs.count else { return }
        crumbs.removeLast(crumbs.count - depth)
        refresh()
    }

    func selectStorage(_ id: UInt32) {
        storageID = id
        crumbs = []
        refresh()
    }

    func download(_ items: [Entry]) {
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else {
            status = "Folders can't be downloaded. Open it and pick files."
            return
        }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        run("Downloading \(files.count) file(s)…", { () -> URL in
            var last = dir
            for f in files {
                let dest = uniqueURL(dir.appendingPathComponent(f.name))
                try MTPEngine.shared.download(id: f.id, to: dest)
                last = dest
            }
            return last
        }) { last in
            NSWorkspace.shared.activateFileViewerSelecting([last])
        }
    }

    func upload(_ urls: [URL]) {
        let storage = storageID, parent = parentID
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false }
        guard !files.isEmpty else {
            status = "Drop files, not folders."
            return
        }
        run("Sending \(files.count) file(s)…", {
            for u in files {
                try MTPEngine.shared.upload(u, name: u.lastPathComponent, storage: storage, parent: parent)
            }
        }) { _ in self.refresh() }
    }

    func delete(_ items: [Entry]) {
        guard !items.isEmpty else { return }
        let names = items.map(\.name).joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Delete \(items.count) item(s) from \(deviceName)?"
        alert.informativeText = names
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        run("Deleting…", {
            for i in items { try MTPEngine.shared.delete(id: i.id) }
        }) { _ in self.refresh() }
    }

    func newFolder() {
        guard let name = promptForText(title: "New folder", placeholder: "Name"), !name.isEmpty else { return }
        let storage = storageID, parent = parentID
        run("Creating folder…", {
            try MTPEngine.shared.createFolder(name: name, storage: storage, parent: parent)
        }) { _ in self.refresh() }
    }

    // MARK: edit round-trip

    private func edit(_ entry: Entry) {
        let storage = storageID, parent = parentID
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kindlemtp-\(entry.id)-\(entry.name)")
        run("Opening \(entry.name)…", { () -> (String, Bool) in
            try MTPEngine.shared.download(id: entry.id, to: tmp)
            let data = try Data(contentsOf: tmp)
            let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
            let body = bom ? data.dropFirst(3) : data[...]
            guard let text = String(data: body, encoding: .utf8)
                    ?? String(data: body, encoding: .isoLatin1) else {
                throw MTPError(message: "\(entry.name) is not readable as text.")
            }
            return (text, bom)
        }) { text, bom in
            self.editing = EditSession(id: entry.id, name: entry.name, parent: parent,
                                       storage: storage, hadBOM: bom, text: text)
        }
    }

    func saveEdit() {
        guard let session = editing else { return }
        editing = nil
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kindlemtp-save-\(session.name)")
        run("Saving \(session.name)…", {
            var data = Data()
            if session.hadBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(Data(session.text.utf8))
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MTPEngine.shared.replace(old: session.id, with: tmp, name: session.name,
                                         storage: session.storage, parent: session.parent)
        }) { _ in self.refresh() }
    }
}

// MARK: - Small helpers

extension String {
    var pathExtensionLower: String { (self as NSString).pathExtension.lowercased() }
}

func uniqueURL(_ url: URL) -> URL {
    var candidate = url
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        candidate = url.deletingLastPathComponent().appendingPathComponent(name)
        n += 1
    }
    return candidate
}

func promptForText(title: String, placeholder: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

func humanSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var store = Store()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            fileList
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 440)
        .onAppear { store.connect() }
        .sheet(item: $store.editing) { _ in EditorSheet(store: store) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Outside the group below: this is the only way back when connect fails.
            Button { store.connect() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .help("Reconnect")
                .disabled(store.busy)

            Group {
            if store.storages.count > 1 {
                Picker("", selection: Binding(get: { store.storageID },
                                              set: { store.selectStorage($0) })) {
                    ForEach(store.storages) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            breadcrumbs

            Spacer()

            Button { store.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
            Button { pickAndUpload() } label: { Image(systemName: "arrow.up.doc") }
                .help("Send files to Kindle")
            Button { store.download(selected) } label: { Image(systemName: "arrow.down.doc") }
                .help("Download selected")
                .disabled(selected.isEmpty)
            Button { store.delete(selected) } label: { Image(systemName: "trash") }
                .help("Delete selected")
                .disabled(selected.isEmpty)
            }
            .disabled(store.busy || !store.connected)
        }
        .padding(8)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            Button(store.currentStorage?.name ?? "Kindle") { store.navigate(toDepth: 0) }
                .buttonStyle(.link)
            ForEach(Array(store.crumbs.enumerated()), id: \.element.id) { index, crumb in
                Text("›").foregroundStyle(.secondary)
                Button(crumb.name) { store.navigate(toDepth: index + 1) }
                    .buttonStyle(.link)
            }
        }
        .lineLimit(1)
    }

    private var fileList: some View {
        List(store.entries, selection: $store.selection) { entry in
            HStack {
                Image(systemName: entry.isFolder ? "folder.fill" : icon(for: entry))
                    .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(entry.name)
                Spacer()
                if !entry.isFolder {
                    Text(humanSize(entry.size))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.open(entry) }
            .tag(entry.id)
        }
        .overlay {
            if store.entries.isEmpty && !store.busy {
                Text(store.connected ? "Empty folder — drop files here" : "No Kindle connected")
                    .foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.upload(urls)
            return true
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if store.busy { ProgressView().controlSize(.small) }
            Text(store.deviceName.isEmpty ? store.status : "\(store.deviceName) — \(store.status)")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if let p = store.progress {
                ProgressView(value: p).frame(width: 120)
            } else if let s = store.currentStorage, s.total > 0 {
                Text("\(humanSize(s.free)) free of \(humanSize(s.total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var selected: [Entry] {
        store.entries.filter { store.selection.contains($0.id) }
    }

    private func icon(for entry: Entry) -> String {
        TEXT_EXTS.contains(entry.name.pathExtensionLower) ? "doc.text" : "book.closed"
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        if panel.runModal() == .OK { store.upload(panel.urls) }
    }
}

struct EditorSheet: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.editing?.name ?? "").font(.headline)
                Spacer()
                Button("Cancel") { store.editing = nil }.keyboardShortcut(.cancelAction)
                Button("Save to Kindle") { store.saveEdit() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            TextEditor(text: Binding(get: { store.editing?.text ?? "" },
                                     set: { store.editing?.text = $0 }))
                .font(.system(.body, design: .monospaced))
        }
        .frame(width: 720, height: 520)
    }
}

/// `KindleMTP.app/Contents/MacOS/KindleMTP --probe` — headless check that the MTP
/// layer works, without needing to click through the UI. Also the smoke test.
private func probeAndExit() -> Never {
    precondition(uniqueURL(URL(fileURLWithPath: "/nonexistent/a.txt")).lastPathComponent == "a.txt")
    precondition("My Clippings.TXT".pathExtensionLower == "txt")
    precondition(humanSize(0) != "")

    do {
        let (name, storages) = try MTPEngine.shared.connect()
        print("device: \(name)")
        for s in storages {
            print("storage \(s.id): \(s.name) — \(humanSize(s.free)) free of \(humanSize(s.total))")
            for e in try MTPEngine.shared.list(storage: s.id, parent: MTP_ROOT) {
                print("  \(e.isFolder ? "[dir] " : "      ")\(e.name)\(e.isFolder ? "" : "  \(humanSize(e.size))")")
            }
        }
        MTPEngine.shared.disconnect()
        print("probe ok")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

@main
struct KindleMTPApp: App {
    init() {
        if CommandLine.arguments.contains("--probe") { probeAndExit() }
    }

    var body: some Scene {
        WindowGroup("Kindle") { ContentView() }
            .defaultSize(width: 860, height: 560)
    }
}
