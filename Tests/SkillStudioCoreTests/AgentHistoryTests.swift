import XCTest
@testable import SkillStudioCore

final class AgentHistoryTests: XCTestCase {
    private let path = "/fixture/skills/example/SKILL.md"
    private let timestamp = "2026-09-21T01:00:00Z"
    private func skill(_ agent: AgentKind) -> Skill {
        Skill(id: "fixture", agent: agent, name: "example", summary: "", sourcePath: path, scope: "fixture", lastDiskContent: "# Example", activeVersionID: UUID())
    }
    private func jsonl(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { result, row in result.append(try JSONSerialization.data(withJSONObject: row)); result.append(10) }
    }
    func testClaudeMatchesSuccessfulReadAndCapturesWriteOnlyAfterResult() throws {
        func row(_ id: String, _ type: String, _ content: Any, stop: String = "") -> [String: Any] {
            ["uuid":id,"sessionId":"fixture-session","type":type,"timestamp":timestamp,"message":["role":type,"content":content,"stop_reason":stop,"model":"fixture-model"]]
        }
        let rows: [[String: Any]] = [row("u1", "user", "Create the fixture."),
            row("a1", "assistant", [["type":"tool_use","id":"read","name":"Read","input":["file_path":path]]]),
            row("r1", "user", [["type":"tool_result","tool_use_id":"read","content":"# Example"]]),
            row("a2", "assistant", [["type":"tool_use","id":"write","name":"Write","input":["file_path":"/fixture/report.md","content":"fixture"]]]),
            row("r2", "user", [["type":"tool_result","tool_use_id":"write","content":"Success"]]),
            row("a3", "assistant", [["type":"text","text":"Finished." ]], stop:"end_turn")]
        let runs = try ClaudeRunHistoryAdapter.parse(jsonl(rows), sourceLog:"/fixture/log.jsonl", skill:skill(.claude), versions:[])
        XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs[0].prompt, "Create the fixture.")
        XCTAssertEqual(runs[0].artifacts.first?.path, "/fixture/report.md")
        XCTAssertEqual(runs[0].capture?.kind, "claude.skill_read")
        var failed = rows
        failed[2] = row("r1", "user", [["type":"tool_result","tool_use_id":"read","is_error":true,"content":"Failed"]])
        XCTAssertTrue(try ClaudeRunHistoryAdapter.parse(jsonl(failed), sourceLog:"/fixture/log", skill:skill(.claude), versions:[]).isEmpty)
        XCTAssertTrue(try ClaudeRunHistoryAdapter.parse(jsonl(Array(rows.dropLast())), sourceLog:"/fixture/log", skill:skill(.claude), versions:[]).isEmpty)
    }
    func testGeminiJSONAndJSONLUpdatesRewindAndFailedReads() throws {
        let user: [String: Any] = ["id":"u1","timestamp":timestamp,"type":"user","content":[["text":"Use the fixture."]]]
        let tools: [String: Any] = ["id":"a1","timestamp":timestamp,"type":"gemini","content":"","toolCalls":[["id":"read","name":"read_file","args":["file_path":path],"status":"success","result":[["functionResponse":["response":["output":"# Example"]]]]]]]
        let answer: [String: Any] = ["id":"a2","timestamp":timestamp,"type":"gemini","content":"Finished.","tokens":["total":20],"model":"fixture-model"]
        let meta: [String: Any] = ["sessionId":"fixture-session","projectHash":"fixture-project"]
        var whole = meta; whole["messages"] = [user,tools,answer]
        let expected = try GeminiRunHistoryAdapter.parse(JSONSerialization.data(withJSONObject: whole), sourceLog:"/fixture/log", skill:skill(.gemini), versions:[])
        XCTAssertEqual(expected.count, 1)
        XCTAssertEqual(HistoryParsing.toolResult([["functionResponse":["response":["output":"# Example"]]]]), "# Example")
        let updated = try GeminiRunHistoryAdapter.parse(jsonl([meta,user,tools,answer,answer]), sourceLog:"/fixture/log", skill:skill(.gemini), versions:[])
        XCTAssertEqual(expected, updated)
        let rewind = try GeminiRunHistoryAdapter.parse(jsonl([meta,user,tools,answer,["$rewindTo":"a1"]]), sourceLog:"/fixture/log", skill:skill(.gemini), versions:[])
        XCTAssertTrue(rewind.isEmpty)
        var failedTools = tools; failedTools["toolCalls"] = [["id":"read","name":"read_file","args":["file_path":path],"status":"error"]]
        XCTAssertTrue(try GeminiRunHistoryAdapter.parse(jsonl([meta,user,failedTools,answer]), sourceLog:"/fixture/log", skill:skill(.gemini), versions:[]).isEmpty)
        var incomplete = answer; incomplete.removeValue(forKey:"tokens")
        XCTAssertTrue(try GeminiRunHistoryAdapter.parse(jsonl([meta,user,tools,incomplete]), sourceLog:"/fixture/log", skill:skill(.gemini), versions:[]).isEmpty)
    }
}
