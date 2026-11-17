import AVFoundation
import CryptoKit
import os
import XCTest
import UIKit
@testable import LauncherPreview

final class GameAudioTests: XCTestCase {
    func testAudioTransitionsAreSerializedAndQuitIgnoresAnOlderInterruption() async {
        let queue = DispatchQueue(label: "horizon.audio.test")
        let notifications = NotificationCenter()
        let transitions = OSAllocatedUnfairLock(initialState: [Bool]())
        let audio = GameAudio(queue: queue, notifications: notifications) { active in
            XCTAssertFalse(Thread.isMainThread)
            transitions.withLock { $0.append(active) }
        }
        func endInterruption() {
            notifications.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
            )
        }
        func drain() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }

        audio.stop()
        await drain()
        XCTAssertEqual(transitions.withLock { $0 }, [false])

        audio.start()
        await drain()
        endInterruption()
        await drain()
        XCTAssertEqual(transitions.withLock { $0 }, [false, true, true])

        // Capture the old observer's event before the queued Quit removes it.
        queue.suspend()
        audio.stop()
        audio.start()
        endInterruption()
        queue.resume()
        await drain()
        XCTAssertEqual(transitions.withLock { $0 }, [false, true, true, false, true])

        audio.stop()
        await drain()
        endInterruption()
        await drain()
        XCTAssertEqual(transitions.withLock { $0 }, [false, true, true, false, true, false])
    }
}

@MainActor
final class GameLinkRefreshTests: XCTestCase {
    func testAnAlreadyCancelledRefreshDoesNotRequestState() async {
        var requests = 0
        let game = GameLink { _ in requests += 1; return ["phase": "title"] }
        let refresh = Task { await game.refresh() }
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(game.phase, .unknown)
    }

    func testAnOlderRefreshCannotReplaceNewerStateOrVersion() async {
        let firstEntered = expectation(description: "first refresh")
        let secondEntered = expectation(description: "second refresh")
        var replies: [CheckedContinuation<[String: Any], Never>] = []
        let game = GameLink { command in
            XCTAssertEqual(command, "launcher-state")
            return await withCheckedContinuation { reply in
                replies.append(reply)
                if replies.count == 1 { firstEntered.fulfill() }
                else { secondEntered.fulfill() }
            }
        }
        let first = Task { await game.refresh() }
        await fulfillment(of: [firstEntered], timeout: 2)
        let second = Task { await game.refresh() }
        await fulfillment(of: [secondEntered], timeout: 2)
        replies[1].resume(returning: ["phase": "title", "version": "current"])
        await second.value
        XCTAssertEqual(game.phase, .title)
        replies[0].resume(returning: ["phase": "waiting", "version": "stale"])
        await first.value
        XCTAssertEqual(game.phase, .title)
        XCTAssertEqual(game.version, "current")
    }

    func testACancelledRefreshDoesNotPublishItsReply() async {
        let entered = expectation(description: "held refresh")
        var hold = false
        var reply: CheckedContinuation<[String: Any], Never>?
        let game = GameLink { _ in
            if !hold { return ["phase": "title", "version": "current"] }
            return await withCheckedContinuation { pending in
                reply = pending
                entered.fulfill()
            }
        }
        await game.refresh()
        hold = true
        let refresh = Task { await game.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        refresh.cancel()
        reply?.resume(returning: ["phase": "waiting", "version": "cancelled"])
        await refresh.value
        XCTAssertEqual(game.phase, .title)
        XCTAssertEqual(game.version, "current")
    }
}

final class FormattingTests: XCTestCase {
    func testGameFileDetectionRequiresARegularManifestFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("horizon-resources.json")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertFalse(GameFolder.containsGameFiles(at: root))
        try FileManager.default.removeItem(at: marker)
        try Data("{}".utf8).write(to: marker)
        XCTAssertTrue(GameFolder.containsGameFiles(at: root))
        try FileManager.default.removeItem(at: marker)
        let target = root.appendingPathComponent("actual-manifest.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        XCTAssertTrue(GameFolder.containsGameFiles(at: root))
        try FileManager.default.removeItem(at: target)
        XCTAssertFalse(GameFolder.containsGameFiles(at: root))
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root)
        XCTAssertFalse(GameFolder.containsGameFiles(at: root))
    }

    func testSensitiveContinuationsDoNotEndAtAnArbitraryBracket() {
        let text = "[12:00:00] [Render thread/INFO]: access_token:\n[opaque-fixture-value]\n[12:00:01] [Render thread/INFO]: shader ready\n"
        let safe = Diagnostics.redactExport(text)
        XCTAssertFalse(safe.contains("opaque-fixture-value"))
        XCTAssertTrue(safe.contains("shader ready"))
    }

    func testBoundedReadDropsTheWholeLeadingPartialMessage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: file)}
        let text = "[12:00:00] [Render thread/INFO]: access_token:\n" + String(repeating: "A", count: Diagnostics.limit) + "\nopaque-fixture-value\n[12:00:01] [Render thread/INFO]: shader ready\n"
        try Data(text.utf8).write(to: file)
        let safe = Diagnostics.redactExport(try Diagnostics.read(file))
        XCTAssertFalse(safe.contains("opaque-fixture-value"))
        XCTAssertTrue(safe.contains("shader ready"))
    }

    func testFullDiagnosticsExportPreservesNewestGameFailureWithinBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: root)}
        let launcher = root.appendingPathComponent("launcher")
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: launcher, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let marker = "[12:00:01] LATEST-GAME-FAILURE\n"
        let tail = Data(("\n" + marker).utf8)
        var full = Data(repeating: 65, count: Diagnostics.limit - tail.count)
        for index in stride(from: 79, to: full.count, by: 80) {full[index] = 10}
        full.append(tail)
        for url in [launcher.appendingPathComponent("launcher.log"), launcher.appendingPathComponent("launcher-previous.log"), game.appendingPathComponent("logs/latest.log"), game.appendingPathComponent("logs/previous.log")] {
            try full.write(to: url)
        }
        let data = try Data(contentsOf: Diagnostics.export(folder: launcher, gameFolder: game))
        XCTAssertLessThanOrEqual(data.count, 4 * Diagnostics.limit)
        let text = String(decoding: data, as: UTF8.self)
        let current = try XCTUnwrap(text.components(separatedBy: "--- Game current ---\n").last)
        XCTAssertTrue(current.contains(marker), "Export must retain the newest error, not truncate it to fit headers")
    }

    func testDiagnosticsExportKeepsReadableLogsWhenAnotherLogCannotBeOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("launcher")
        let game = root.appendingPathComponent("game")
        let logs = game.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: launcher.appendingPathComponent("launcher-previous.log"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        Diagnostics.record("launcher ready", folder: launcher)
        try Data("[12:00:01] shader failed\naccess_token=private-fixture\n".utf8)
            .write(to: logs.appendingPathComponent("latest.log"))

        let report = try String(contentsOf: Diagnostics.export(folder: launcher, gameFolder: game), encoding: .utf8)
        XCTAssertTrue(report.contains("--- Launcher previous ---\nLog unavailable during export.\n"))
        XCTAssertTrue(report.contains("--- Game previous ---\nNo log recorded yet.\n"))
        XCTAssertTrue(report.contains("launcher ready"))
        XCTAssertTrue(report.contains("shader failed"))
        XCTAssertFalse(report.contains("private-fixture"))
    }

    func testDiagnosticsAreBoundedRedactedAndExportOnlyLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let launcher = root.appendingPathComponent("launcher")
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at:game.appendingPathComponent("logs"),withIntermediateDirectories:true)
        try Data("private-account-fixture".utf8).write(to:game.appendingPathComponent("accounts.json"))
        for text in ["Authorization: Bearer confidential-value", "refresh_token:\nshort-value", "cookie=abc"] {
            XCTAssertTrue(Diagnostics.redact(text).contains("redacted"))
        }
        XCTAssertTrue(Diagnostics.redact("shader: unexpected token in vertex stage").contains("unexpected token"))
        for _ in 0..<90 {Diagnostics.record(String(repeating:"shader diagnostic ",count:1000),folder:launcher)}
        for name in ["launcher.log","launcher-previous.log"] {
            XCTAssertLessThanOrEqual(try Data(contentsOf:launcher.appendingPathComponent(name)).count,Diagnostics.limit)
        }
        try Data("shader Complementary: pipeline failed\naccess_token=confidential-value\n".utf8).write(to:game.appendingPathComponent("logs/latest.log"))
        let result = try Diagnostics.export(folder:launcher,gameFolder:game)
        let bytes = try Data(contentsOf:result)
        XCTAssertLessThanOrEqual(bytes.count,4*Diagnostics.limit)
        let text = String(decoding:bytes,as:UTF8.self)
        XCTAssertTrue(text.contains("Complementary: pipeline failed"))
        XCTAssertFalse(text.contains("confidential-value"))
        XCTAssertFalse(text.contains("private-account-fixture"))
        XCTAssertEqual(try Diagnostics.export(folder:launcher,gameFolder:game),result)
    }

    func testColorsDecorationsAndReset() {
        let r = MinecraftFormatting.runs("§aGreen §lBold§oItalic§nUnder§mStrike§rPlain")
        XCTAssertEqual(r[0].style.color, 0x55FF55)
        XCTAssertTrue(r[1].style.bold)
        XCTAssertTrue(r[2].style.italic)
        XCTAssertTrue(r[3].style.underline)
        XCTAssertTrue(r[4].style.strike)
        XCTAssertEqual(r.last?.style, MinecraftFormatting.Style())
        XCTAssertEqual(MinecraftFormatting.plain("§6§lHYPIXEL§r\n§7SkyBlock"), "HYPIXEL\nSkyBlock")
    }
    func testColorResetsDecorationAndRGBIsOneColor() {
        let r = MinecraftFormatting.runs("§lBold§cRed§x§1§2§3§4§5§6Hex")
        XCTAssertFalse(r[1].style.bold)
        XCTAssertEqual(r[1].style.color, 0xFF5555)
        XCTAssertEqual(r[2].style.color, 0x123456)
    }
    func testUnicodeUnknownSequencesAndTrailingSectionSignArePreserved() {
        XCTAssertEqual(MinecraftFormatting.plain("§b世界 🧱 §z literal §"), "世界 🧱 §z literal §")
        XCTAssertTrue(MinecraftFormatting.runs("§kSecret")[0].style.obfuscated)
        XCTAssertEqual(MinecraftFormatting.plain("§LUPPER"), "UPPER")
    }
    func testWorldCreationJSONCarriesAllFields() throws {
        var settings = WorldCreationSettings()
        settings.name = "A world with spaces"; settings.seed = "hello world"; settings.mode = "hardcore"
        settings.flat = true; settings.structures = false
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, settings.name)
        XCTAssertEqual(json["seed"] as? String, "hello world")
        XCTAssertEqual(json["mode"] as? String, "hardcore")
        XCTAssertEqual(json["flat"] as? Bool, true)
        XCTAssertEqual(json["structures"] as? Bool, false)
        XCTAssertEqual(json["bonus_chest"] as? Bool, false)
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    func testEmptyAndFailedResponsesAreVisibleFailures() async {
        let empty = GameOptions(request: { _ in ["ok": true] })
        await empty.load()
        XCTAssertNotNil(empty.issue)
        XCTAssertTrue(empty.options.isEmpty)
        XCTAssertFalse(empty.loading)
        let failed = GameOptions(request: { _ in ["error": "Disconnected"] })
        await failed.load()
        XCTAssertEqual(failed.issue, "Disconnected")
    }
    func testPartialOptionsRemainUsableAndIdentifyMissingControls() async {
        let model = GameOptions(request: { _ in ["options": ["autoJump": ["type": "bool", "value": false]]] })
        await model.load()
        XCTAssertNil(model.issue)
        XCTAssertNotNil(model.options["autoJump"])
        XCTAssertTrue(model.unavailable.contains("Graphics"))
    }
    func testToggleUpdatesOnlyAfterAcknowledgement() async {
        var value = false
        let model = GameOptions(request: { line in
            if line.hasPrefix("options-set autoJump ") {
                value = line.hasSuffix("true")
                return ["option": ["type": "bool", "value": value]]
            }
            return ["options": ["autoJump": ["type": "bool", "value": value]]]
        })
        await model.load()
        let issue = await model.set("autoJump", "true")
        XCTAssertNil(issue)
        XCTAssertTrue(model.options["autoJump"]?.flag == true)
        await model.load()
        XCTAssertTrue(model.options["autoJump"]?.flag == true)
        let noAck = GameOptions(request: { _ in ["ok": true] })
        let noAckIssue = await noAck.set("autoJump", "true")
        XCTAssertNotNil(noAckIssue)
    }
    func testPreviewFixtureCoversEveryLauncherSetting() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "EngineOptions", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(Set(options.keys), Set(GameOptions.groups.flatMap { $0.rows.map(\.key) }))
    }
}

@MainActor
final class LauncherAsyncTests: XCTestCase {
    func testPreparedFileStagesOutsideManualScanAndCleansOnlyItsCopy() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("private import staging fixture".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var staged: URL?
        let model = GameFilesDownload(importArchive: { line in
            XCTAssertTrue(line.hasPrefix("import-game-files "))
            let file = URL(fileURLWithPath: String(line.dropFirst("import-game-files ".count)))
            staged = file
            XCTAssertNotEqual(file.deletingLastPathComponent().resolvingSymlinksInPath(),
                              GameFolder.documents.resolvingSymlinksInPath())
            XCTAssertEqual(try? Data(contentsOf: file), bytes)
            return ["ok": true, "kind": "resources"]
        })
        await model.importPreparedFile(source)
        XCTAssertNotNil(staged)
        if let staged { XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path)) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        if case .done = model.state {} else { XCTFail("Import did not finish: \(model.state)") }
    }

    private func hits(_ id: String) -> [String: Any] { ["hits": [["project_id": id, "title": id]]] }

    func testOldPackSearchCannotOverwriteNewResults() async {
        var pending: [String: CheckedContinuation<Any?, Never>] = [:]
        let store = PackStore(fetch: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            return await withCheckedContinuation { pending[query] = $0 }
        })
        let old = Task { await store.search(.resource, query: "old") }
        while pending["old"] == nil { await Task.yield() }
        let new = Task { await store.search(.shader, query: "new") }
        while pending["new"] == nil { await Task.yield() }
        pending.removeValue(forKey: "new")?.resume(returning: hits("new"))
        await new.value
        pending.removeValue(forKey: "old")?.resume(returning: hits("old"))
        await old.value
        XCTAssertEqual(store.results.map(\.id), ["new"])
        XCTAssertFalse(store.searching)
        XCTAssertNil(store.failed)
    }

    func testOldPackFailureCannotEndNewSearchOrSetError() async {
        var pending: [String: CheckedContinuation<Any?, Never>] = [:]
        let store = PackStore(fetch: { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            return await withCheckedContinuation { pending[query] = $0 }
        })
        let old = Task { await store.search(.resource, query: "old") }
        while pending["old"] == nil { await Task.yield() }
        let new = Task { await store.search(.shader, query: "new") }
        while pending["new"] == nil { await Task.yield() }
        pending.removeValue(forKey: "old")?.resume(returning: nil)
        await old.value
        XCTAssertTrue(store.searching)
        XCTAssertNil(store.failed)
        pending.removeValue(forKey: "new")?.resume(returning: hits("new"))
        await new.value
        XCTAssertEqual(store.results.map(\.id), ["new"])
    }

    func testDuplicatePackInstallDoesNotStartAnotherRequest() async {
        var resume: CheckedContinuation<Any?, Never>?
        let store = PackStore(fetch: { _ in await withCheckedContinuation { resume = $0 } })
        let project = ModrinthProject(id: "test", kind: .resource, title: "Test", summary: "", author: "", downloads: 0, icon: nil, gameVersions: [])
        let first = Task { await store.install(project, version: "26.3") }
        while resume == nil { await Task.yield() }
        if case .success = await store.install(project, version: "26.3") { XCTFail("Duplicate install succeeded") }
        XCTAssertNotNil(store.downloading[project.id])
        resume?.resume(returning: [])
        _ = await first.value
        XCTAssertNil(store.downloading[project.id])
    }

    func testPackDownloadKeepsItsSearchKindAndDoesNotReplaceAnExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shaders = root.appendingPathComponent("shader")
        let resources = root.appendingPathComponent("resource")
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let existingShader = shaders.appendingPathComponent("shared.zip")
        let existingResource = resources.appendingPathComponent("shared.zip")
        try Data("existing shader".utf8).write(to: existingShader)
        try Data("existing resource".utf8).write(to: existingResource)
        let temporary = root.appendingPathComponent("download")
        let downloaded = Data("new shader fixture".utf8)
        let sha512 = SHA512.hash(data: downloaded).map { String(format: "%02X", $0) }.joined()
        var hashes = ["sha512": sha512]
        try downloaded.write(to: temporary)
        let store = PackStore(fetch: { url in
            if url.path.hasSuffix("/search") {
                return ["hits": [["project_id": "fixture", "title": "Fixture"]]]
            }
            return [["game_versions": ["26.3"], "files": [
                ["filename": "shared.zip", "url": "https://example.invalid/shared.zip", "primary": true,
                 "size": downloaded.count, "hashes": hashes],
            ]]]
        }, transfer: { request in
            let url = try XCTUnwrap(request.url)
            return (temporary, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, folder: { root.appendingPathComponent($0.rawValue) })

        await store.search(.shader, query: "")
        let shader = try XCTUnwrap(store.results.first)
        await store.search(.resource, query: "")
        XCTAssertEqual(store.results.first?.kind, .resource)
        let first = await store.install(shader, version: "26.3")
        if case let .failure(error) = first { XCTFail(error.message) }
        let installed = try first.get()
        XCTAssertEqual(installed.file, "shared (2).zip")
        XCTAssertEqual(try Data(contentsOf: shaders.appendingPathComponent(installed.file)), downloaded)
        XCTAssertEqual(try Data(contentsOf: existingShader), Data("existing shader".utf8))
        XCTAssertEqual(try Data(contentsOf: existingResource), Data("existing resource".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))

        var corrupted = downloaded
        corrupted[0] ^= 1
        for invalid in [corrupted, Data(downloaded.dropLast())] {
            try invalid.write(to: temporary)
            switch await store.install(shader, version: "26.3") {
            case .success: XCTFail("An unverified pack was installed")
            case let .failure(error): XCTAssertTrue(error.message.contains("checksum or size"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: shaders.path)),
                           ["shared.zip", "shared (2).zip"])
        }
        hashes = ["sha1": Insecure.SHA1.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()]
        try downloaded.write(to: temporary)
        let legacy = try await store.install(shader, version: "26.3").get()
        XCTAssertEqual(legacy.file, "shared (3).zip")
        XCTAssertEqual(try Data(contentsOf: shaders.appendingPathComponent(legacy.file)), downloaded)
    }

    func testStaleGameFileCompletionDoesNotImportOrReplaceSharedArchive() async throws {
        let shared = GameFolder.documents.appendingPathComponent("horizon-download.zip")
        let previous = try? Data(contentsOf: shared)
        let sentinel = Data("keep-current-download".utf8)
        try sentinel.write(to: shared)
        defer { if let previous { try? previous.write(to: shared) } else { try? FileManager.default.removeItem(at: shared) } }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("stale-download".utf8).write(to: source)
        let imported = expectation(description: "Stale completion must not import")
        imported.isInverted = true
        let model = GameFilesDownload(importArchive: { _ in imported.fulfill(); return ["ok": true] })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/test.zip")!)
        model.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
        await fulfillment(of: [imported], timeout: 0.15)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(try Data(contentsOf: shared), sentinel)
    }
}

@MainActor
final class PackMutationTests: XCTestCase {
    func testSimultaneousResourceTogglesMergeAfterFirstAcknowledgement() async {
        var packs: [String] = []
        var writes: [[String]] = []
        var firstAck: CheckedContinuation<Void, Never>?
        let choices = PackChoices(request: { line in
            if line == "options-get resourcePacks" { return ["options": ["resourcePacks": ["value": packs]]] }
            if line.hasPrefix("options-set resourcePacks ") {
                let json = String(line.dropFirst("options-set resourcePacks ".count))
                let next = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] ?? []
                writes.append(next)
                if writes.count == 1 { await withCheckedContinuation { firstAck = $0 } }
                packs = next
                return ["ok": true]
            }
            return ["selected": NSNull()]
        })
        let first = Task { await choices.set("a.zip", kind: .resource, on: true) }
        while firstAck == nil { await Task.yield() }
        let second = Task { await choices.set("b.zip", kind: .resource, on: true) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(writes.count, 1)
        firstAck?.resume()
        let firstError = await first.value; let secondError = await second.value
        XCTAssertNil(firstError); XCTAssertNil(secondError)
        XCTAssertEqual(writes, [["file/a.zip"], ["file/a.zip", "file/b.zip"]])
        XCTAssertEqual(choices.resourcePacks, ["file/a.zip", "file/b.zip"])
    }
    func testActivePackDisableFailureLeavesFileUntouched() async {
        var deleted = false
        let choices = PackChoices(request: { line in
            if line.hasPrefix("options-set") { return ["error": "Reload failed"] }
            return ["options": ["resourcePacks": ["value": ["file/a.zip"]]]]
        })
        let error = await choices.remove("a.zip", kind: .resource, delete: { deleted = true; return nil })
        XCTAssertEqual(error, "Reload failed")
        XCTAssertFalse(deleted)
        XCTAssertTrue(choices.isOn("a.zip", kind: .resource))
    }
    func testUnconfirmedDisableDoesNotDeleteFile() async {
        var deleted = false
        let choices = PackChoices(request: { line in
            if line.hasPrefix("options-set") { return ["ok": true] }
            return ["options": ["resourcePacks": ["value": ["file/a.zip"]]]]
        })
        let error = await choices.remove("a.zip", kind: .resource, delete: { deleted = true; return nil })
        XCTAssertNotNil(error)
        XCTAssertFalse(deleted)
    }
    func testDeletionRunsOnlyAfterConfirmedDisable() async {
        var packs = ["file/a.zip"]
        var events: [String] = []
        let choices = PackChoices(request: { line in
            if line.hasPrefix("options-set") { events.append("disable"); packs = []; return ["ok": true] }
            return ["options": ["resourcePacks": ["value": packs]]]
        })
        let error = await choices.remove("a.zip", kind: .resource, delete: { events.append("delete"); XCTAssertTrue(packs.isEmpty); return nil })
        XCTAssertNil(error)
        XCTAssertEqual(events, ["disable", "delete"])
    }
}

@MainActor
final class DownloadScreenTests: XCTestCase {
    func testBridgeFailureShowsRecoveryActionsAndIsLoggedOnce() async {
        var messages: [String] = []
        let model = DownloadModel(request: { _ in ["error": "Game connection unavailable"] },
                                  diagnostic: { messages.append($0) })
        await model.refresh()
        XCTAssertEqual(model.phase, .failed("Game connection unavailable"))
        await model.refresh()
        XCTAssertEqual(messages.count, 1)
    }

    func testPreRetryPollCannotReplaceTheCurrentDownloadState() async {
        var oldPoll: CheckedContinuation<[String: Any], Never>?
        let polling = expectation(description: "old status request is in flight")
        var polls = 0
        let model = DownloadModel(request: { command in
            if command == "download-retry" { return ["ok": true] }
            polls += 1
            switch polls {
            case 1: return ["phase": "failed", "error": "Old download failed"]
            case 2: return await withCheckedContinuation {
                oldPoll = $0
                polling.fulfill()
            }
            default: return ["phase": "downloading", "received": 20, "total": 50]
            }
        }, diagnostic: { _ in })
        await model.refresh()
        let stale = Task { await model.refresh() }
        await fulfillment(of: [polling], timeout: 2)
        await model.retry()
        await model.refresh()
        oldPoll?.resume(returning: ["phase": "failed", "error": "Old download failed"])
        await stale.value
        XCTAssertEqual(model.phase, .downloading)
        XCTAssertEqual(model.received, 20)
        XCTAssertEqual(model.total, 50)
    }
}

@MainActor
final class AutomaticGameFilesTests: XCTestCase {
    func testChangingDownloadOriginClearsThePreviousToken() {
        let model = GameFilesDownload(diagnostic: { _ in })
        for link in [
            "https://other.example.invalid/archive",
            "https://files.example.invalid:444/archive",
            "http://files.example.invalid/archive",
            "",
        ] {
            model.link = "https://files.example.invalid/initial"
            model.token = "fixture"
            model.link = "https://FILES.example.invalid:443/new-file"
            XCTAssertEqual(model.token, "fixture")
            model.link = link
            XCTAssertTrue(model.token.isEmpty, link)
        }
    }

    func testSavedCredentialCanOnlyBeReadForItsStoredOrigin() throws {
        let origin = try XCTUnwrap(GameFilesOrigin(URL(string: "https://files.example.invalid/archive")))
        let data = try JSONEncoder().encode(GameFilesCredential(origin: origin, token: "fixture"))
        XCTAssertEqual(GameFilesCredential.token(from: data, for: origin), "fixture")
        for link in [
            "http://files.example.invalid/archive",
            "https://files.example.invalid:444/archive",
            "https://other.example.invalid/archive",
        ] {
            XCTAssertNil(GameFilesCredential.token(from: data, for: GameFilesOrigin(URL(string: link))), link)
        }
        XCTAssertNil(GameFilesCredential.token(from: Data("legacy-token".utf8), for: origin))
    }

    func testCustomDownloadRejectsBearerTokenOverHTTP() {
        let model = GameFilesDownload(diagnostic: { _ in })
        model.link = "http://127.0.0.1:1/files.zip"
        model.token = "private-test-token"
        model.start()
        XCTAssertEqual(model.state, .failed("Use an HTTPS link to download with an access token."))
        XCTAssertFalse(model.busy)
    }

    func testRedirectOnlyKeepsAuthorizationOnTheSameHTTPSOrigin() {
        let previous = URL(string: "https://files.example.invalid/archive")!
        for (url, keepsAuthorization) in [
            ("https://files.example.invalid:443/redirect", true),
            ("https://files.example.invalid:444/redirect", false),
            ("https://cdn.example.invalid/redirect", false),
            ("http://files.example.invalid/redirect", false),
        ] {
            var redirect = URLRequest(url: URL(string: url)!)
            redirect.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            let safe = GameFilesDownload.redirectRequest(redirect, from: previous)
            XCTAssertEqual(safe.value(forHTTPHeaderField: "Authorization"),
                           keepsAuthorization ? "Bearer fixture" : nil, url)
            XCTAssertEqual(safe.url, redirect.url)
        }
    }

    func testDownloadErrorFactsKeepCodesButNeverIncludeCredentials() {
        let underlying = NSError(domain:NSPOSIXErrorDomain,code:61,userInfo:[NSLocalizedDescriptionKey:"private-password"])
        let error = NSError(domain:NSURLErrorDomain,code:NSURLErrorCannotConnectToHost,userInfo:[
            NSUnderlyingErrorKey:underlying,
            NSURLErrorFailingURLErrorKey:URL(string:"https://user:pass@example.invalid/file?access_token=private-value")!,
            NSLocalizedDescriptionKey:"private-password"
        ])
        let facts = GameFilesDownload.errorFacts(error)
        XCTAssertTrue(facts.contains("kind=connection"))
        XCTAssertTrue(facts.contains("code=-1004"))
        XCTAssertTrue(facts.contains("underlying_code=61"))
        for sensitive in ["private", "example.invalid", "https", "user:pass"] {XCTAssertFalse(facts.contains(sensitive))}
    }

    func testFailedTransferLogsItsStageAndSafeNativeError() async {
        let restore = temporarilyRemoveResourceMarker()
        defer {restore()}
        var events: [String] = []
        let model = GameFilesDownload(automaticSource:{["url":"http://127.0.0.1:1/fixture?access_token=never-log-this"]},diagnostic:{events.append($0)})
        await model.startAutomatic()
        let deadline = Date().addingTimeInterval(10)
        while model.busy, Date() < deadline {try? await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(model.busy)
        XCTAssertTrue(events.contains(where:{$0.contains("source_lookup_result has_url=true has_error=false")}))
        XCTAssertTrue(events.contains(where:{$0.contains("transfer_start endpoint=custom")}))
        XCTAssertTrue(events.contains(where:{$0.contains("transfer_failed") && $0.contains("domain=NSURLErrorDomain")}))
        XCTAssertFalse(events.joined().contains("never-log-this"))
        XCTAssertFalse(events.joined().contains("127.0.0.1"))
    }

    private func temporarilyRemoveResourceMarker() -> () -> Void {
        let marker = GameFolder.resources.appendingPathComponent("horizon-resources.json")
        let previous = try? Data(contentsOf: marker)
        try? FileManager.default.removeItem(at: marker)
        return {
            if let previous { try? previous.write(to: marker) }
            else { try? FileManager.default.removeItem(at: marker) }
        }
    }

    func testAutomaticSourceFailureNeedsExplicitRetry() async {
        let restore = temporarilyRemoveResourceMarker()
        defer { restore() }
        var calls = 0
        var events: [String] = []
        let model = GameFilesDownload(automaticSource: {
            calls += 1
            return ["error": "Fixture source is unavailable"]
        }, diagnostic: {events.append($0)})
        model.link = "https://example.invalid/private.zip"
        model.token = "private-test-token"
        await model.startAutomatic()
        XCTAssertEqual(model.state, .failed("Fixture source is unavailable"))
        await model.startAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 1)
        await model.startAutomatic()
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.link, "https://example.invalid/private.zip")
        XCTAssertEqual(model.token, "private-test-token")
        XCTAssertTrue(events.contains(where:{$0.contains("source_lookup_failed")}))
        XCTAssertFalse(events.contains(where:{$0.contains("transfer_start")}))
        XCTAssertFalse(events.joined().contains("private-test-token"))
    }

    func testCancelWhileResolvingSourceCannotStartLateDownload() async {
        var resume: CheckedContinuation<[String: Any], Never>?
        let model = GameFilesDownload(automaticSource: {
            await withCheckedContinuation { resume = $0 }
        })
        let start = Task { await model.startAutomatic() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(model.busy)
        model.cancel()
        resume?.resume(returning: ["url": "https://example.invalid/must-not-fetch.zip"])
        await start.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.busy)
    }

    func testStaleBackgroundExpirationDoesNotEndTheRetry() async throws {
        let restore = temporarilyRemoveResourceMarker()
        defer { restore() }
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"]
                               ?? "http://127.0.0.1:1/game.zip")
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var events: [String] = []
        let first = UIBackgroundTaskIdentifier(rawValue: 1)
        let second = UIBackgroundTaskIdentifier(rawValue: 2)
        let model = GameFilesDownload(
            automaticSource: { ["url": url + "?delay=1"] },
            diagnostic: { events.append($0) },
            backgroundTasks: GameFilesBackgroundTasks(begin: { expire in
                expirations.append(expire)
                return expirations.count == 1 ? first : second
            }, end: { ended.append($0) })
        )
        defer { model.cancel() }

        await model.startAutomatic()
        model.cancel()
        await model.startAutomatic()
        XCTAssertEqual(expirations.count, 2)
        guard expirations.count == 2 else { return }
        expirations[0]()
        XCTAssertEqual(ended, [first])
        XCTAssertFalse(events.contains { $0.contains("background_time_expired") })
        expirations[1]()
        expirations[1]()
        XCTAssertEqual(ended, [first, second])
        XCTAssertEqual(events.filter { $0.contains("background_time_expired") }.count, 1)
        model.cancel()
        XCTAssertEqual(ended, [first, second])
    }

    func testCancelledSetupTaskCannotStartLateDownload() async {
        var resume: CheckedContinuation<[String: Any], Never>?
        let model = GameFilesDownload(automaticSource: {
            await withCheckedContinuation { resume = $0 }
        })
        let start = Task { await model.startAutomatic() }
        while resume == nil { await Task.yield() }
        start.cancel()
        resume?.resume(returning: ["url": "http://127.0.0.1:1/must-not-fetch.zip"])
        await start.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.busy)
    }

    func testFilesArrivingDuringSourceLookupDoNotGetReplaced() async throws {
        let marker = GameFolder.resources.appendingPathComponent("horizon-resources.json")
        let previous = try? Data(contentsOf: marker)
        try? FileManager.default.removeItem(at: marker)
        defer {
            if let previous { try? previous.write(to: marker) }
            else { try? FileManager.default.removeItem(at: marker) }
        }
        var resume: CheckedContinuation<[String: Any], Never>?
        let model = GameFilesDownload(automaticSource: {
            await withCheckedContinuation { resume = $0 }
        })
        let start = Task { await model.startAutomaticallyIfNeeded() }
        while resume == nil { await Task.yield() }
        try FileManager.default.createDirectory(at: GameFolder.resources, withIntermediateDirectories: true)
        try Data("manual-import-fixture".utf8).write(to: marker)
        resume?.resume(returning: ["url": "http://127.0.0.1:1/must-not-fetch.zip"])
        await start.value
        XCTAssertEqual(model.state, .done("Game files are already installed."))
        XCTAssertEqual(try Data(contentsOf: marker), Data("manual-import-fixture".utf8))
        XCTAssertFalse(model.busy)
    }

    func testAlreadyInstalledFilesDoNotDownload() async throws {
        let marker = GameFolder.resources.appendingPathComponent("horizon-resources.json")
        let previous = try? Data(contentsOf: marker)
        try FileManager.default.createDirectory(at: GameFolder.resources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marker)
        defer {
            if let previous { try? previous.write(to: marker) }
            else { try? FileManager.default.removeItem(at: marker) }
        }
        var calls = 0
        let model = GameFilesDownload(automaticSource: { calls += 1; return [:] })
        await model.startAutomaticallyIfNeeded()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.state, .idle)
    }

    func testCancelledLocalImportDoesNotLeaveSetupBusy() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("local-import-fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var imports = 0
        let model = GameFilesDownload(importArchive: { _ in
            imports += 1
            return ["ok": true]
        }, diagnostic: { message in
            if message.contains("file_import_start") {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let operation = Task { await model.importPreparedFile(file) }
        await operation.value
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.busy, "Cancelled file hydration must allow a retry")
    }

    func testAutomaticDownloadUsesResourceImporterAndKeepsCustomCredentials() async throws {
        let restore = temporarilyRemoveResourceMarker()
        defer { restore() }
        guard let url = ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the loopback download fixture")
        }
        let imported = expectation(description: "Downloaded fixture reaches importer")
        let model = GameFilesDownload(importArchive: { line in
            XCTAssertTrue(line.hasPrefix("import-game-files "))
            let file = URL(fileURLWithPath: String(line.dropFirst("import-game-files ".count)))
            XCTAssertEqual(try? Data(contentsOf: file), Data("horizon-download-fixture".utf8))
            imported.fulfill()
            return ["ok": true, "kind": "resources"]
        }, automaticSource: { ["url": url] })
        model.link = "https://example.invalid/private.zip"
        model.token = "private-test-token"
        await model.startAutomatic()
        await fulfillment(of: [imported], timeout: 10)
        if case .done = model.state {} else { XCTFail("Download did not finish: \(model.state)") }
        XCTAssertEqual(model.link, "https://example.invalid/private.zip")
        XCTAssertEqual(model.token, "private-test-token")
    }

    func testFilesArrivingDuringTransferDoNotGetReplaced() async throws {
        let restore = temporarilyRemoveResourceMarker()
        defer { restore() }
        guard let url = ProcessInfo.processInfo.environment["HORIZON_DOWNLOAD_FIXTURE_URL"] else {
            throw XCTSkip("Requires the loopback download fixture")
        }
        var imports = 0
        let model = GameFilesDownload(importArchive: { _ in
            imports += 1
            return ["ok": true, "kind": "resources"]
        }, automaticSource: { ["url": url + "?delay=1"] })
        await model.startAutomatic()
        let marker = GameFolder.resources.appendingPathComponent("horizon-resources.json")
        try FileManager.default.createDirectory(at: GameFolder.resources, withIntermediateDirectories: true)
        try Data("manual-transfer-fixture".utf8).write(to: marker)
        for _ in 0..<100 where model.busy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(model.state, .done("Game files are already installed."))
        XCTAssertEqual(try Data(contentsOf: marker), Data("manual-transfer-fixture".utf8))
    }
}


@MainActor
final class SkinHeadTests: XCTestCase {
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    func testOldLookupCannotReplaceNewAccountFace() async {
        let oldFace = image(.red), newFace = image(.blue)
        var pending: [String: CheckedContinuation<UIImage?, Never>] = [:]
        let head = SkinHead { name in
            await withCheckedContinuation { pending[name] = $0 }
        }
        let old = Task { await head.load("Old") }
        while pending["Old"] == nil { await Task.yield() }
        let current = Task { await head.load("Current") }
        while pending["Current"] == nil { await Task.yield() }
        pending.removeValue(forKey: "Current")?.resume(returning: newFace)
        await current.value
        XCTAssertTrue(head.face === newFace)
        pending.removeValue(forKey: "Old")?.resume(returning: oldFace)
        await old.value
        XCTAssertTrue(head.face === newFace, "A previous account lookup must not replace the selected account")
    }

    func testCachedAndClearedSelectionInvalidatePendingLookup() async {
        let cached = image(.green), oldFace = image(.red)
        var pending: CheckedContinuation<UIImage?, Never>?
        let head = SkinHead { name in
            if name == "Cached" { return cached }
            return await withCheckedContinuation { pending = $0 }
        }
        await head.load("Cached")
        let old = Task { await head.load("Old") }
        while pending == nil { await Task.yield() }
        await head.load("Cached")
        pending?.resume(returning: oldFace); pending = nil
        await old.value
        XCTAssertTrue(head.face === cached)

        let other = Task { await head.load("Other") }
        while pending == nil { await Task.yield() }
        await head.load(nil)
        pending?.resume(returning: oldFace); pending = nil
        await other.value
        XCTAssertNil(head.face)
    }

    func testCancelledLookupDoesNotPublishFace() async {
        let face = image(.red)
        var pending: CheckedContinuation<UIImage?, Never>?
        let head = SkinHead { _ in
            await withCheckedContinuation { pending = $0 }
        }
        let load = Task { await head.load("Cancelled") }
        while pending == nil { await Task.yield() }
        load.cancel(); pending?.resume(returning: face)
        await load.value
        XCTAssertNil(head.face)
    }
}
