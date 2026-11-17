import SwiftUI
import UIKit

/// Only diagnostic text is exported; never account stores, options or game data.
enum Diagnostics {
    static let limit = 1024 * 1024
    private static let entryLimit = 32 * 1024
    private static let lock = NSLock()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonDiagnostics", isDirectory: true)
    }
    private static let sensitive = [
        "accesstoken", "refreshtoken", "idtoken", "token =", "token :", "user code",
        "access_token", "refresh_token", "id_token", "token:", "token=", "token\"",
        "authorization", "bearer", "password", "secret", "cookie", "xbl3.0",
        "device_code", "user_code", "sessionid", "session_id", "api_key", "accesskey",
    ]
    // Each marker is a literal required by its pattern. Avoid expensive searches
    // for email addresses and other identifiers on ordinary status lines.
    private static let patterns: [(regex: NSRegularExpression, marker: String?, minimumBytes: Int)] = [
        (#"https?://[^\s]+"#, "://", 0),
        (#"\beyJ[A-Za-z0-9_.-]+"#, "eyj", 4),
        (#"[A-Za-z0-9_./+=-]{129,}"#, nil, 129),
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "@", 0),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, ".", 7),
        (#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "-", 36),
        (#"/(?:Users|var/mobile)/[^\s]+"#, "/", 0),
    ].compactMap { pattern, marker, minimumBytes in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (regex, marker, minimumBytes)
    }
    private static let entryStart = try? NSRegularExpression(pattern: #"^(?:\[\d{2}:\d{2}:\d{2}\]|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"#)
    private static func beginsEntry(_ line: String) -> Bool {
        entryStart?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
    static func redact(_ text: String) -> String {
        guard text.utf8.count <= entryLimit else { return "[oversized log entry omitted]" }
        let lowercase = text.lowercased()
        if sensitive.contains(where: { lowercase.contains($0) }) {
            return "[redacted sensitive log message]"
        }
        return text.components(separatedBy: .newlines).map { line in
            let lowercaseLine = line.lowercased()
            let bytes = line.utf8.count
            var safe = line
            for rule in patterns where bytes >= rule.minimumBytes {
                if let marker = rule.marker, !lowercaseLine.contains(marker) { continue }
                safe = rule.regex.stringByReplacingMatches(
                    in: safe, range: NSRange(safe.startIndex..., in: safe), withTemplate: "[redacted]"
                )
            }
            return safe
        }.joined(separator: "\n")
    }
    static func bounded(_ text: String, maximum: Int = limit) -> Data {
        var bytes = Data(text.utf8)
        if bytes.count > maximum {
            bytes = bytes.prefix(maximum - 32)
            // Decode/re-encode safely when the byte boundary splits Unicode.
            bytes = Data((String(decoding: bytes, as: UTF8.self) + "\n[truncated]\n").utf8)
        }
        return bytes
    }
    static func record(_ message: String, folder: URL = directory) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let current = folder.appendingPathComponent("launcher.log")
            let previous = folder.appendingPathComponent("launcher-previous.log")
            let data = bounded("\(ISO8601DateFormatter().string(from: Date())) \(redact(message))\n", maximum: entryLimit)
            if !FileManager.default.fileExists(atPath: current.path) { try Data().write(to: current) }
            let size = (try current.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if size + data.count > limit {
                let tail = try read(current)
                try bounded(redactExport(tail)).write(to: previous, options: .atomic)
                try data.write(to: current, options: .atomic)
                return
            }
            let file = try FileHandle(forWritingTo: current);defer {try? file.close()}
            try file.seekToEnd();try file.write(contentsOf: data)
        } catch { /* Logging must never interrupt gameplay or recurse into logging. */ }
    }
    static func read(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer {try? file.close()}
        let length = try file.seekToEnd()
        try file.seek(toOffset: length > UInt64(limit) ? length - UInt64(limit) : 0)
        let data = try file.read(upToCount: limit) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard length > UInt64(limit) else {return text}
        // A truncated message may leave a short secret after its label was cut off.
        let completeLines = String(text.drop(while: {$0 != "\n"}).dropFirst()).components(separatedBy: "\n")
        guard let first = completeLines.firstIndex(where: beginsEntry) else {return ""}
        return completeLines[first...].joined(separator: "\n")
    }
    static func redactExport(_ text:String) -> String {
        var hidingContinuation = false
        return text.components(separatedBy:.newlines).map { line in
            if line.utf8.count > entryLimit {
                hidingContinuation = true
                return "[oversized log line omitted]"
            }
            // Rust entries start with [time]; launcher entries start with an ISO date.
            if hidingContinuation {
                guard beginsEntry(line) else { return "[redacted continuation]" }
                hidingContinuation = false
            }
            let safe = redact(line)
            if safe == "[redacted sensitive log message]" { hidingContinuation = true }
            return safe
        }.joined(separator:"\n")
    }

    /// Trim only after redaction, preserving complete recent lines and valid UTF-8.
    static func exportTail(_ text: String, maximum: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maximum else {return text}
        let marker = "[older lines omitted]\n"
        guard maximum > marker.utf8.count else {return ""}
        let suffix = String(decoding: data.suffix(maximum - marker.utf8.count), as: UTF8.self)
        guard let newline = suffix.firstIndex(of: "\n") else {return marker}
        return marker + suffix[suffix.index(after: newline)...]
    }

    /// An unreadable source must not prevent exporting the other logs.
    private static func exportSnapshot(_ url: URL) -> String {
        let unavailable = "Log unavailable during export.\n"
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return unavailable
            }
            return try read(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return "No log recorded yet.\n"
        } catch {
            // File errors can contain private paths. Keep the report text generic.
            return unavailable
        }
    }

    private static func launcherSnapshots(_ folder: URL) -> (previous: String, current: String) {
        // Capture both files under the writer lock so a rotation cannot split
        // the snapshot. Redaction and formatting happen after releasing it.
        lock.lock()
        defer { lock.unlock() }
        return (
            exportSnapshot(folder.appendingPathComponent("launcher-previous.log")),
            exportSnapshot(folder.appendingPathComponent("launcher.log"))
        )
    }

    static func export(folder: URL = directory, gameFolder: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let exportDir = folder.appendingPathComponent("Export", isDirectory: true)
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destination = exportDir.appendingPathComponent("Horizon-diagnostics.txt")
        var output = "Horizon mobile diagnostics\nVersion: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")\niOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nSensitive lines and common identifiers are redacted. Review before sharing.\n"
        let gameHome = gameFolder ?? ProcessInfo.processInfo.environment["HORIZON_HOME"].map {URL(fileURLWithPath:$0)} ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("horizon")
        let launcher = launcherSnapshots(folder)
        let entries = [
            ("Launcher previous", launcher.previous),
            ("Launcher current", launcher.current),
            ("Game previous", exportSnapshot(gameHome.appendingPathComponent("logs/previous.log"))),
            ("Game current", exportSnapshot(gameHome.appendingPathComponent("logs/latest.log"))),
        ]
        let headings = entries.map { "\n--- \($0.0) ---\n" }
        let overhead = output.utf8.count + headings.reduce(0) { $0 + $1.utf8.count }
        let budget = max(0, 4 * limit - overhead) / entries.count
        for (index, entry) in entries.enumerated() {
            output += headings[index]
            output += exportTail(redactExport(entry.1), maximum: budget)
        }
        try bounded(output, maximum: 4 * limit).write(to:destination,options:.atomic)
        return destination
    }
}

struct LogsSettings: View {
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SectionHeader(title:"Logs")
            Button {
                exporting = true;error = nil
                Task {
                    do {exportURL = try await Task.detached(priority:.utility) {try Diagnostics.export()}.value}
                    catch {self.error = "Could not export logs. Please try again."}
                    exporting = false
                }
            } label: {Label(exporting ? "Preparing logs…" : "Export log file",systemImage:"square.and.arrow.up")}
            .disabled(exporting).accessibilityIdentifier("export-diagnostics")
            if let error {Text(error).foregroundStyle(.red)}
        }.padding(16).card()
        .sheet(isPresented: Binding(get:{exportURL != nil},set:{if !$0 {exportURL = nil}})) {
            if let exportURL {DiagnosticFileExport(url:exportURL) {self.exportURL = nil}}
        }
    }
}
private struct DiagnosticFileExport: UIViewControllerRepresentable {
    let url: URL
    let finish: () -> Void
    func makeCoordinator() -> Coordinator {Coordinator(finish:finish)}
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting:[url],asCopy:true)
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "diagnostic-file-export"
        return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: () -> Void
        init(finish:@escaping () -> Void) {self.finish = finish}
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {finish()}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {finish()}
    }
}
