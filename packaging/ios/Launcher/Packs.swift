import CryptoKit
import SwiftUI
import UIKit

/// What a pack is for, and where the game keeps it.
enum PackKind: String, CaseIterable, Identifiable {
    case resource, shader

    var id: String { rawValue }
    var title: String { self == .resource ? "Resource Packs" : "Shader Packs" }
    var folder: URL {
        GameFolder.documents.appendingPathComponent(self == .resource ? "resourcepacks" : "shaderpacks")
    }
    /// Modrinth's search facets: resource packs, or shader packs in the Iris/OptiFine format the game reads.
    var facets: String {
        self == .resource
            ? #"[["project_type:resourcepack"]]"#
            : #"[["project_type:shader"],["categories:iris","categories:optifine"]]"#
    }
}

/// A project from Modrinth's search.
struct ModrinthProject: Identifiable, Equatable {
    let id: String
    let kind: PackKind
    let title: String
    let summary: String
    let author: String
    let downloads: Int
    let icon: URL?
    let gameVersions: [String]
}

private struct PackFileIntegrity: Sendable {
    private enum Algorithm: Sendable { case sha512, sha1 }
    private let algorithm: Algorithm
    private let expectedHash: String
    private let expectedSize: Int64

    init?(metadata: [String: Any]) {
        guard let size = metadata["size"] as? Int, size > 0,
              let hashes = metadata["hashes"] as? [String: String] else { return nil }
        let algorithm: Algorithm = hashes["sha512"] == nil ? .sha1 : .sha512
        let key = algorithm == .sha512 ? "sha512" : "sha1"
        let length = algorithm == .sha512 ? 128 : 40
        guard let hash = hashes[key]?.lowercased(), hash.utf8.count == length,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.algorithm = algorithm
        expectedHash = hash
        expectedSize = Int64(size)
    }

    func matches(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha512 = SHA512()
        var sha1 = Insecure.SHA1()
        var count: Int64 = 0
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            guard Int64(chunk.count) <= expectedSize - count else { return false }
            count += Int64(chunk.count)
            switch algorithm {
            case .sha512: sha512.update(data: chunk)
            case .sha1: sha1.update(data: chunk)
            }
        }
        guard count == expectedSize else { return false }
        let digest = algorithm == .sha512 ? Array(sha512.finalize()) : Array(sha1.finalize())
        return digest.map { String(format: "%02x", $0) }.joined() == expectedHash
    }
}

/// Packs from Modrinth (api.modrinth.com, v2): search, then the newest version made for the game's Minecraft
/// version (else the newest at all, said so), whose primary file goes straight into the pack folder.
@MainActor
final class PackStore: ObservableObject {
    @Published private(set) var results: [ModrinthProject] = []
    @Published private(set) var searching = false
    @Published private(set) var failed: String?
    /// Project ids being downloaded, with how far along.
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var installed: [PackKind: [String]] = [:]

    typealias Fetch = @MainActor (URL) async -> Any?
    typealias Transfer = @MainActor (URLRequest) async throws -> (URL, URLResponse)
    private let fetch: Fetch
    private let transfer: Transfer
    private let folder: (PackKind) -> URL
    private var searchRevision: UInt64 = 0
    init(fetch: @escaping Fetch = { await PackStore.get($0) },
         transfer: @escaping Transfer = { try await URLSession.shared.download(for: $0) },
         folder: @escaping (PackKind) -> URL = { $0.folder }) {
        self.fetch = fetch
        self.transfer = transfer
        self.folder = folder
    }

    private static let api = "https://api.modrinth.com/v2"

    func search(_ kind: PackKind, query: String) async {
        searchRevision &+= 1
        let revision = searchRevision
        searching = true
        failed = nil
        results = []
        defer { if revision == searchRevision { searching = false } }
        var parts = URLComponents(string: "\(Self.api)/search")!
        parts.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "facets", value: kind.facets),
            URLQueryItem(name: "index", value: query.isEmpty ? "downloads" : "relevance"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = parts.url else { return }
        let response = await fetch(url)
        guard revision == searchRevision, !Task.isCancelled else { return }
        guard let json = response as? [String: Any], let hits = json["hits"] as? [[String: Any]] else {
            failed = "Modrinth didn't answer. Check the connection and try again."
            return
        }
        failed = nil
        results = hits.compactMap { hit in
            guard let id = hit["project_id"] as? String, let title = hit["title"] as? String else { return nil }
            return ModrinthProject(
                id: id, kind: kind, title: title, summary: hit["description"] as? String ?? "",
                author: hit["author"] as? String ?? "", downloads: hit["downloads"] as? Int ?? 0,
                icon: (hit["icon_url"] as? String).flatMap(URL.init(string:)),
                gameVersions: hit["versions"] as? [String] ?? []
            )
        }
    }

    /// What a download put in the pack folder: the file's name, and a word when it was made for another version.
    struct Installed {
        let file: String
        let note: String?
    }

    /// Download `project`'s file for the game's Minecraft version into the project's pack folder.
    func install(_ project: ModrinthProject, version: String) async -> Result<Installed, PackError> {
        guard downloading[project.id] == nil else { return .failure(PackError("This pack is already downloading.")) }
        downloading[project.id] = 0
        defer { downloading[project.id] = nil }
        let versions = await fetch(URL(string: "\(Self.api)/project/\(project.id)/version")!) as? [[String: Any]] ?? []
        // Newest first, as Modrinth lists them: one made for this Minecraft, else the newest of all.
        let fitting = versions.first { ($0["game_versions"] as? [String] ?? []).contains(version) }
        guard let chosen = fitting ?? versions.first,
              let files = chosen["files"] as? [[String: Any]],
              let file = files.first(where: { $0["primary"] as? Bool == true }) ?? files.first,
              let link = (file["url"] as? String).flatMap(URL.init(string:)),
              link.scheme?.lowercased() == "https", link.host != nil,
              let name = file["filename"] as? String,
              // A file name from the network names a file here: no folders in it.
              !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), name.lowercased().hasSuffix(".zip")
        else {
            return .failure(PackError("\(project.title) has no file to download."))
        }
        guard let integrity = PackFileIntegrity(metadata: file) else {
            return .failure(PackError("Modrinth did not provide a valid checksum and size for this pack."))
        }
        var request = URLRequest(url: link)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        do {
            let (temporary, response) = try await transfer(request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure(PackError("Modrinth refused the download of \(project.title)."))
            }
            let verification = Task.detached(priority: .utility) { try integrity.matches(temporary) }
            let matches = try await withTaskCancellationHandler {
                try await verification.value
            } onCancel: {
                verification.cancel()
            }
            try Task.checkCancellation()
            guard matches else {
                return .failure(PackError("The downloaded pack did not match Modrinth's checksum or size. Try downloading it again."))
            }
            let directory = folder(project.kind)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = directory.appendingPathComponent(name)
            let stem = original.deletingPathExtension().lastPathComponent
            var destination = original
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent("\(stem) (\(suffix)).zip")
                suffix += 1
            }
            // Never silently replace a local pack or a different project's ZIP.
            try FileManager.default.moveItem(at: temporary, to: destination)
            reloadInstalled()
            let made = (chosen["game_versions"] as? [String])?.last ?? "another version"
            let note = fitting == nil ? "It was made for Minecraft \(made), so it may not look right on \(version)." : nil
            return .success(Installed(file: destination.lastPathComponent, note: note))
        } catch {
            return .failure(PackError(error.localizedDescription))
        }
    }

    /// The zips and folders in each pack folder.
    func reloadInstalled() {
        for kind in PackKind.allCases {
            let directory = folder(kind)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            installed[kind] = names
                .filter { name in
                    guard !name.hasPrefix(".") else { return false }
                    return name.lowercased().hasSuffix(".zip")
                        || (kind == .shader && name.hasSuffix(".hshader"))
                        || Self.isFolder(directory.appendingPathComponent(name))
                }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    func remove(_ name: String, kind: PackKind) -> String? {
        do {
            try FileManager.default.removeItem(at: folder(kind).appendingPathComponent(name))
            reloadInstalled()
            return nil
        } catch { return error.localizedDescription }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// Modrinth asks every client to name itself.
    private static let agent = "heyskylo/horizon-ios launcher (github.com/heyskylo/horizon-ios)"

    private static func get(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct PackError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Which packs the game uses: `resourcePacks` in options.txt (`file/<name>` entries, the last on top) and the
/// shader pack (`shader-pack`, config/iris.properties).
@MainActor
final class PackChoices: ObservableObject {
    @Published private(set) var resourcePacks: [String] = []
    @Published private(set) var shaderPack: String?
    @Published private(set) var shaderStatus: String?
    @Published private(set) var shaderNotes: [String] = []

    typealias Request = @MainActor (String) async -> [String: Any]
    private let request: Request
    private var shaderKeys: [String: String] = [:]
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var issue: String?

    init(request: @escaping Request = { await Bridge.send($0) }) { self.request = request }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }

    func load() async {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return }
        let error = await reload()
        if !Task.isCancelled { issue = error }
    }

    private func readResources() async -> String? {
        let answer = await request("options-get resourcePacks")
        if let error = answer.error { return error }
        guard let packs = ((answer["options"] as? [String: Any])?["resourcePacks"] as? [String: Any])?["value"] as? [String] else {
            return "The active resource packs could not be read. Try again."
        }
        resourcePacks = packs
        return nil
    }

    private func readShaders() async -> String? {
        let shaders = await request("shader-pack list")
        if let error = shaders.error { return error }
        guard let selected = shaders["selected"], selected is NSNull || selected is String else {
            return "The selected shader pack could not be read. Try again."
        }
        var keys: [String: String] = [:]
        for pack in shaders["packs"] as? [[String: Any]] ?? [] {
            if let name = pack["name"] as? String, let key = pack["key"] as? String {
                keys[name] = key
            }
        }
        shaderKeys = keys
        shaderPack = selected as? String
        shaderNotes = []
        shaderStatus = nil
        if shaderPack != nil {
            if let runtime = shaders["runtime"] as? [String: Any],
               let programs = runtime["programs"] as? [String] {
                shaderStatus = programs.isEmpty ? "No supported effects loaded. Normal rendering is active."
                    : "Running \(programs.count) shader programs."
                shaderNotes = runtime["notes"] as? [String] ?? []
            } else {
                shaderStatus = "Selected. Open a world to load this pack, then return here for its status."
            }
        } else if let failure = shaders["last_disabled"] as? [String: Any],
                  let name = failure["pack"] as? String {
            shaderStatus = "\(name) was turned off because it could not load."
            shaderNotes = failure["notes"] as? [String] ?? []
        }
        return nil
    }

    private func reload() async -> String? {
        let resources = await readResources()
        guard !Task.isCancelled else { return nil }
        let shaders = await readShaders()
        return resources ?? shaders
    }

    func isOn(_ name: String, kind: PackKind) -> Bool {
        if kind == .resource { return resourcePacks.contains("file/\(name)") }
        guard let shaderPack else { return false }
        return shaderPack == name || shaderPack == shaderKeys[name]
    }

    /// Each mutation reads the latest confirmed state while holding the queue lock. A second toggle
    /// cannot derive its whole resource-pack list from the cache preceding the first write.
    func set(_ name: String, kind: PackKind, on: Bool) async -> String? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let error = await setLocked(name, kind: kind, on: on)
        if !Task.isCancelled { issue = error }
        return error
    }

    private func setLocked(_ name: String, kind: PackKind, on: Bool) async -> String? {
        let readError = kind == .resource ? await readResources() : await readShaders()
        guard !Task.isCancelled else { return nil }
        if let readError { return readError }
        // Off is a global engine command for shaders. Never use it to
        // disable a different shader that became active while this waited.
        guard isOn(name, kind: kind) != on else { return nil }
        let answer: [String: Any]
        switch kind {
        case .resource:
            var packs = resourcePacks.filter { $0 != "file/\(name)" }
            if on { packs.append("file/\(name)") }
            guard let data = try? JSONSerialization.data(withJSONObject: packs),
                  let list = String(data: data, encoding: .utf8) else { return "That pack name can't be saved." }
            answer = await request("options-set resourcePacks \(list)")
        case .shader:
            let key = shaderKeys[name] ?? name
            guard let data = try? JSONSerialization.data(withJSONObject: ["name": key, "enabled": on]),
                  let selection = String(data: data, encoding: .utf8) else { return "That shader name can't be saved." }
            answer = await request("shader-pack-set \(selection)")
        }
        if let error = answer.error { return error }
        // Confirm the result before another mutation, or a deletion, can use it.
        let error = kind == .resource ? await readResources() : await readShaders()
        if let error { return error }
        guard isOn(name, kind: kind) == on else { return "The pack change was not confirmed. Try again." }
        return nil
    }

    /// Hold the same lock through disable + confirmation + deletion. Failed/unknown disable state
    /// leaves the file intact. The closure allows a focused test without changing real pack folders.
    func remove(_ name: String, kind: PackKind, delete: () -> String?) async -> String? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let readError = kind == .resource ? await readResources() : await readShaders()
        guard !Task.isCancelled else { return nil }
        if let readError { issue = readError; return readError }
        if isOn(name, kind: kind), let error = await setLocked(name, kind: kind, on: false) {
            if !Task.isCancelled { issue = error }
            return error
        }
        guard !Task.isCancelled else { return nil }
        let error = delete()
        issue = error
        return error
    }

}

// MARK: - The page

struct PacksPage: View {
    @ObservedObject var link: GameLink
    @StateObject private var store = PackStore()
    @StateObject private var choices = PackChoices()
    @State private var kind = PackKind.resource
    @State private var query = ""
    @State private var notice: String?

    var body: some View {
        let visibleResults = store.results.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 16) {
            Picker("Kind", selection: $kind) {
                ForEach(PackKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            installedSection
            if let issue = choices.issue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warn)
            }

            if kind == .shader, let status = choices.shaderStatus {
                Text(status).font(Theme.sans(12)).foregroundStyle(Theme.text)
                ForEach(Array(choices.shaderNotes.prefix(8).enumerated()), id: \.offset) { _, note in
                    Text(note).font(Theme.sans(11)).foregroundStyle(Theme.warn)
                        .textSelection(.enabled)
                }
            }

            SectionHeader(title: "Find on Modrinth")
            Field(title: "SEARCH", placeholder: kind == .resource ? "Faithful, Stay True…" : "Complementary, BSL…",
                  text: $query, keyboard: .default)
                .onSubmit { Task { await store.search(kind, query: query) } }
            if kind == .shader {
                Text("Compatibility varies by pack and settings. Check the runtime notes for unsupported features or loading errors.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
            }
            if let failed = store.failed {
                Label(failed, systemImage: "wifi.exclamationmark").font(Theme.sans(12)).foregroundStyle(Theme.warn)
            }
            if store.searching && visibleResults.isEmpty {
                ProgressView().tint(Theme.accentText).frame(maxWidth: .infinity).padding(24)
            }
            VStack(spacing: 0) {
                ForEach(visibleResults) { project in
                    ProjectRow(project: project, progress: store.downloading[project.id],
                               version: link.version) {
                        Task { await download(project) }
                    }
                    if project != visibleResults.last {
                        Divider().overlay(Theme.border).padding(.leading, 70)
                    }
                }
            }
            .card()
            Text("Packs come from modrinth.com and their authors. Horizon is not affiliated with Modrinth.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
        .task(id: kind) {
            store.reloadInstalled()
            await store.search(kind, query: query)
        }
        .task(id: link.canList) {
            if link.canList { await choices.load() }
        }
        .alert("Packs", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder private var installedSection: some View {
        let rowKind = kind
        let names = store.installed[rowKind] ?? []
        SectionHeader(title: "Installed")
        if names.isEmpty {
            EmptyNote(icon: kind == .resource ? "square.stack.3d.up" : "sun.max",
                      text: "None yet. Find one below, or drop a .zip into Horizon's \(kind == .resource ? "resourcepacks" : "shaderpacks") folder in Files.")
        } else {
            VStack(spacing: 0) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 12) {
                        Text(name).font(Theme.sans(14)).foregroundStyle(Theme.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { choices.isOn(name, kind: rowKind) },
                            set: { on in
                                Haptics.tap()
                                Task {
                                    if let error = await choices.set(name, kind: rowKind, on: on) {
                                        notice = error
                                    }
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(!link.canList)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                if let error = await choices.remove(name, kind: rowKind, delete: {
                                    store.remove(name, kind: rowKind)
                                }) { notice = error }
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    if name != names.last {
                        Divider().overlay(Theme.border).padding(.leading, 14)
                    }
                }
            }
            .card()
            Text(link.canList
                ? "Switch a pack on to use it; hold one to delete it."
                : "Packs can be switched on in a moment.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
    }

    private func download(_ project: ModrinthProject) async {
        Haptics.tap()
        switch await store.install(project, version: link.version) {
        case let .success(installed):
            Haptics.done()
            let name = installed.file
            var said: String
            if link.canList, let error = await choices.set(name, kind: project.kind, on: true) {
                said = "Downloaded \(name), but it couldn't be switched on: \(error)"
            } else {
                said = link.canList ? "\(name) is downloaded and on." : "\(name) is downloaded. Switch it on in a moment."
            }
            if let note = installed.note {
                said += " " + note
            }
            notice = said
        case let .failure(error):
            Haptics.failed()
            notice = error.message
        }
    }
}

private struct ProjectRow: View {
    let project: ModrinthProject
    let progress: Double?
    let version: String
    let download: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: project.icon) { image in
                image.resizable().interpolation(.none).scaledToFill()
            } placeholder: {
                Theme.surfaceSunken
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title).font(Theme.sans(15, .semiBold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(project.summary).font(Theme.sans(11)).foregroundStyle(Theme.textMuted).lineLimit(2)
                HStack(spacing: 6) {
                    Text("by \(project.author)")
                    Text("·")
                    Text("\(project.downloads.formatted(.number.notation(.compactName))) downloads")
                    if !project.gameVersions.contains(version) {
                        Text("·")
                        Text("not tagged \(version)").foregroundStyle(Theme.warn)
                    }
                }
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Group {
                if progress != nil {
                    ProgressView().tint(Theme.accentText)
                } else {
                    Button(action: download) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 26))
                            .foregroundStyle(Theme.accentBright)
                    }
                    .accessibilityLabel("Download \(project.title)")
                }
            }
            .frame(width: 44, height: 44)
        }
        .padding(12)
    }
}
