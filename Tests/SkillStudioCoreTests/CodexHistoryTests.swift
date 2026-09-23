import XCTest
@testable import SkillStudioCore

final class CodexHistoryTests: XCTestCase {
    private let body = "---\nname: fixture\n---\n\n# Fixture\nDo a useful task.\n"
    private func fixture() -> (Skill, SkillVersion) {
        let version = SkillVersion(skillID: "fixture", number: 1, content: body, note: "fixture")
        let skill = Skill(id: "fixture", agent: .codex, name: "fixture", summary: "fixture", sourcePath: "/fixture/skills/example/SKILL.md", scope: "fixture", lastDiskContent: body, activeVersionID: version.id)
        return (skill, version)
    }
    private func lines(readType: String = "read", status: String = "completed", exitCode: Int = 0,
                       path: String = "/fixture/skills/example/SKILL.md", output: String? = nil, finished: Bool = true) throws -> Data {
        let timestamp = "2026-09-21T01:00:00.000Z"
        func row(_ type: String, _ payload: [String: Any]) -> [String: Any] { ["type": type, "timestamp": timestamp, "payload": payload] }
        func item(_ value: [String: Any]) -> [String: Any] { row("event_msg", ["type": "item_completed", "thread_id": "session-fixture", "turn_id": "turn-fixture", "item": value]) }
        let read = item(["type":"CommandExecution", "id":"read-fixture", "status":status, "exit_code":exitCode, "cwd":"/fixture", "stdout":output ?? body, "stderr":"", "aggregated_output":output ?? body,
                         "parsed_cmd":[["type":readType,"path":path,"cmd":"cat /fixture/skills/example/SKILL.md"]]])
        var rows: [[String: Any]] = [row("session_meta", ["id":"session-fixture"]),
            row("event_msg", ["type":"task_started", "turn_id":"turn-fixture", "started_at":timestamp]),
            row("turn_context", ["turn_id":"turn-fixture", "model":"fixture-model"]),
            item(["type":"UserMessage", "id":"prompt-fixture", "content":[["type":"text","text":"Summarize these changes."]]]),
            read, read, // duplicated delivery must not duplicate history
            item(["type":"AgentMessage", "id":"comment-fixture", "phase":"commentary", "content":[["type":"Text","text":"Still working"]]]),
            item(["type":"AgentMessage", "id":"answer-fixture", "phase":"final_answer", "content":[["type":"Text","text":"The final answer."]]])]
        if finished { rows.append(row("event_msg", ["type":"task_complete", "turn_id":"turn-fixture", "duration_ms":2000])) }
        return try rows.reduce(into: Data()) { result, row in result.append(try JSONSerialization.data(withJSONObject: row)); result.append(10) }
    }
    func testCompletedReadLinksActualTurnAndMatchingText() throws {
        let (skill, version) = fixture()
        let runs = try CodexRunHistoryAdapter.parse(lines(), sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].prompt, "Summarize these changes.")
        XCTAssertEqual(runs[0].output, "The final answer.")
        XCTAssertEqual(runs[0].model, "fixture-model")
        XCTAssertEqual(runs[0].durationSeconds, 2)
        XCTAssertEqual(runs[0].versionID, version.id)
        XCTAssertEqual(runs[0].capture?.kind, "codex.skill_read")
        let again = try CodexRunHistoryAdapter.parse(lines(), sourceLog: "/fixture/moved.jsonl", skill: skill, versions: [version])
        XCTAssertEqual(again[0].id, runs[0].id)
    }
    func testLongHistoricalBodyDoesNotMatchShorterRevision() throws {
        let (skill, _) = fixture()
        let short = "# Example\nKeep the response short.\n"
        let long = short + "Include acceptance criteria.\n"
        let v1 = SkillVersion(skillID: skill.id, number: 1, content: long, note: "fixture")
        let v2 = SkillVersion(skillID: skill.id, number: 2, content: short, note: "fixture")
        // A separate stdout and unambiguous single-file cat are the supported complete-read fixture.
        var rows = try lines(output: long).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        for i in rows.indices {
            guard var payload = rows[i]["payload"] as? [String: Any], var item = payload["item"] as? [String: Any], item["type"] as? String == "CommandExecution" else { continue }
            item["stdout"] = long; item["stderr"] = ""
            item["command"] = "cat /fixture/skills/example/SKILL.md"
            item["parsed_cmd"] = [["type":"read", "path":"/fixture/skills/example/SKILL.md", "cmd":"cat /fixture/skills/example/SKILL.md"]]
            payload["item"] = item; rows[i]["payload"] = payload
        }
        let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        let known = try CodexRunHistoryAdapter.parse(data, sourceLog: "/fixture/log", skill: skill, versions: [v2, v1])
        XCTAssertEqual(known.first?.versionID, v1.id)
        let unsaved = try CodexRunHistoryAdapter.parse(data, sourceLog: "/fixture/log", skill: skill, versions: [v2])
        XCTAssertNil(unsaved.first?.versionID)
    }
    func testFileChangeArtifactsRequireSuccessfulCompletion() throws {
        let (skill, version) = fixture()
        var rows = try lines().split(separator:10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String:Any] }
        let change: [String:Any] = ["type":"event_msg", "timestamp":"2026-09-21T01:00:01Z", "payload":[
            "type":"item_completed", "thread_id":"session-fixture", "turn_id":"turn-fixture", "item":[
                "type":"FileChange", "id":"change-fixture", "status":"completed", "changes":["/fixture/report.md":["type":"add"], "/fixture/old.md":["type":"delete"]]]]]
        rows.insert(change, at: rows.count - 1)
        let data = try rows.reduce(into: Data()) { result, row in result.append(try JSONSerialization.data(withJSONObject:row)); result.append(10) }
        let runs = try CodexRunHistoryAdapter.parse(data, sourceLog:"/fixture/log", skill:skill, versions:[version])
        XCTAssertEqual(runs.first?.artifacts.map(\.path), ["/fixture/report.md"])
    }
    func testUnknownHistoricalVersionIsNotGuessed() throws {
        let (skill, version) = fixture()
        let runs = try CodexRunHistoryAdapter.parse(lines(output: "Only part of the file"), sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version])
        XCTAssertEqual(runs.count, 1); XCTAssertNil(runs[0].versionID)
        let roundTrip = try JSONDecoder().decode(SkillRun.self, from: JSONEncoder().encode(runs[0]))
        XCTAssertEqual(roundTrip, runs[0])
    }
    func testRejectsMentionFailedReadWrongPathAndUnfinishedTurn() throws {
        let (skill, version) = fixture()
        for data in [try lines(readType: "unknown"), try lines(status: "failed"), try lines(exitCode: 1), try lines(path: "/fixture/another/SKILL.md"), try lines(finished: false)] {
            XCTAssertTrue(try CodexRunHistoryAdapter.parse(data, sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version]).isEmpty)
        }
    }
    func testTruncatedTailAndReimportPreserveFeedback() throws {
        let (skill, version) = fixture()
        var data = try lines(); data.append(Data("{incomplete".utf8))
        let runs = try CodexRunHistoryAdapter.parse(data, sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version])
        var snapshot = LibrarySnapshot(); snapshot.skills = [skill]; snapshot.versions = [version]
        XCTAssertEqual(RunHistoryMerge.merge(runs, into: &snapshot), 1)
        snapshot.runs[0].rating = .good; snapshot.runs[0].feedback = "Keep this."
        XCTAssertEqual(RunHistoryMerge.merge(runs, into: &snapshot), 0)
        XCTAssertEqual(snapshot.runs.count, 1)
        XCTAssertEqual(snapshot.runs[0].feedback, "Keep this."); XCTAssertEqual(snapshot.runs[0].rating, .good)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try isolatedTestDatabase(url: dir.appendingPathComponent("fixture.sqlite"))
        try db.save(snapshot)
        XCTAssertEqual(try db.load(), snapshot)
    }
    func testAbortedTurnAndOtherThreadReadAreExcluded() throws {
        let (skill, version) = fixture()
        var aborted = try lines(finished: false)
        for type in ["turn_aborted", "task_complete"] {
            aborted.append(try JSONSerialization.data(withJSONObject: ["type":"event_msg", "payload":["type":type,"turn_id":"turn-fixture"]]))
            aborted.append(10)
        }
        XCTAssertTrue(try CodexRunHistoryAdapter.parse(aborted, sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version]).isEmpty)
        let other = try lines().split(separator: 10).reduce(into: Data()) { result, line in
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            var payload = try XCTUnwrap(row["payload"] as? [String: Any])
            if let item = payload["item"] as? [String: Any], item["type"] as? String == "CommandExecution" {
                payload["thread_id"] = "another-session"; row["payload"] = payload
            }
            result.append(try JSONSerialization.data(withJSONObject: row)); result.append(10)
        }
        XCTAssertTrue(try CodexRunHistoryAdapter.parse(other, sourceLog: "/fixture/log.jsonl", skill: skill, versions: [version]).isEmpty)
    }
    func testLegacyRunDecodesWithoutCapture() throws {
        let (_, version) = fixture()
        let run = SkillRun(skillID: "fixture", versionID: version.id, prompt: "fixture", output: "fixture")
        let data = try JSONEncoder().encode(run)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["capture"])
        XCTAssertEqual(try JSONDecoder().decode(SkillRun.self, from: data), run)
    }
    func testDirectoryScanCachesAndDetectsNewCompletion() async throws {
        let (skill, version) = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.jsonl")
        try lines(finished: false).write(to: file)
        let adapter = CodexRunHistoryAdapter(root: root), since = Date(timeIntervalSince1970: 0)
        let first = try await adapter.scan(skill: skill, versions: [version], since: since)
        XCTAssertTrue(first.runs.isEmpty)
        try lines().write(to: file)
        let second = try await adapter.scan(skill: skill, versions: [version], since: since)
        XCTAssertEqual(second.runs.count, 1)
        let cached = try await adapter.scan(skill: skill, versions: [version], since: since)
        XCTAssertEqual(cached.filesRead, 0); XCTAssertEqual(cached.runs, second.runs)
    }
    func testLocalHistoryWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["SKILL_STUDIO_LOCAL_HISTORY_TEST"] == "1",
              let thread = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"] else { throw XCTSkip("Opt-in read-only local history validation") }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let root = home.appendingPathComponent("sessions")
        let paths = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let file = try XCTUnwrap(paths.compactMap { $0 as? URL }.first { $0.lastPathComponent.contains(thread) && $0.pathExtension == "jsonl" })
        let source = home.appendingPathComponent("skills/.system/openai-docs/SKILL.md")
        let content = try String(contentsOf: source)
        let version = SkillVersion(skillID: "local-check", number: 1, content: content, note: "Read-only verification")
        let skill = Skill(id: "local-check", agent: .codex, name: "openai-docs", summary: "", sourcePath: source.path, scope: "local", lastDiskContent: content, activeVersionID: version.id)
        let runs = try CodexRunHistoryAdapter.parse(Data(contentsOf: file), sourceLog: file.path, skill: skill, versions: [version])
        XCTAssertGreaterThan(runs.count, 0)
        print("Verified completed skill-read turns: \(runs.count); matching historical bodies: \(runs.filter { $0.versionID != nil }.count). No prompts or outputs printed.")
    }
}
