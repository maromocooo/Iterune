import XCTest
@testable import SkillStudioCore

final class HistoryImportIntegrityTests: XCTestCase {
    private let path = "/fixture/skills/example/SKILL.md"
    private let timestamp = "2026-09-21T01:00:00Z"
    private let long = "# Example\nKeep the response short.\nInclude acceptance criteria.\n"
    private let short = "# Example\nKeep the response short.\n"
    private enum Form { case full, partial, truncated, unknown, multiple, failed }
    private func parse(_ agent: AgentKind, reads: [(String, Form)], versions: [SkillVersion], secondSession: Bool = false, secondTurn: Bool = false, wrongFile: Bool = false) throws -> [SkillRun] {
        let skill = Skill(id:"fixture",agent:agent,name:"Fixture",summary:"",sourcePath:path,scope:"fixture",lastDiskContent:"NOT historical evidence",activeVersionID:UUID())
        let path = wrongFile ? "/fixture/other/SKILL.md" : self.path
        var rows: [[String:Any]] = []
        func codex(_ payload: [String:Any]) -> [String:Any] { ["type":"event_msg","timestamp":timestamp,"payload":payload.merging(["turn_id":"turn","thread_id":"session"],uniquingKeysWith: { a,_ in a })] }
        func item(_ value: [String:Any]) -> [String:Any] { codex(["type":"item_completed","item":value]) }
        func claude(_ id: String, _ type: String, _ content: Any, final: Bool = false, session: String = "session") -> [String:Any] {
            ["uuid":id,"sessionId":session,"type":type,"timestamp":timestamp,"message":["content":content,"stop_reason":final ? "end_turn" : ""]]
        }
        switch agent {
        case .codex:
            rows = [["type":"session_meta","payload":["id":"session"]],codex(["type":"task_started"]),item(["id":"prompt","type":"UserMessage","content":[["type":"text","text":"Synthetic task"]]])]
            for (i, read) in reads.enumerated() {
                var command = "cat \(path)", output = read.0
                if read.1 == .partial { command = "head -n 10 \(path)" }
                if read.1 == .multiple { command += " /fixture/other" }
                if read.1 == .unknown { output = "File: SKILL.md\n" + output }
                var value: [String:Any] = ["type":"CommandExecution","id":"read\(i)","cwd":"/fixture","status":"completed","exit_code":read.1 == .failed ? 1 : 0,"stdout":output,"stderr":"","command":command,"parsed_cmd":[["type":"read","path":path,"cmd":command]]]
                if read.1 == .truncated { value["truncated"] = true }
                rows.append(item(value))
            }
            if secondSession { rows.append(["type":"session_meta","payload":["id":"other-session"]]) }
            if secondTurn {
                rows.append(codex(["type":"task_started", "turn_id":"other-turn"]))
                rows.append(item(["id":"second-prompt","type":"UserMessage","content":[["type":"text","text":"Second task"]]]))
            }
            rows += [item(["id":"final","type":"AgentMessage","phase":"final_answer","content":[["type":"text","text":"Synthetic output"]]]),codex(["type":"task_complete"])]
            if secondTurn {
                for i in (rows.count - 3)..<rows.count {
                    var payload = rows[i]["payload"] as! [String:Any]; payload["turn_id"] = "other-turn"; rows[i]["payload"] = payload
                }
            }
        case .claude:
            rows = [claude("prompt","user","Synthetic task")]
            for (i, read) in reads.enumerated() {
                var input: [String:Any] = ["file_path":path]
                if read.1 == .partial { input["offset"] = 1; input["limit"] = 20 }
                rows.append(claude("call\(i)","assistant",[["type":"tool_use","id":"read\(i)","name":"Read","input":input]]))
                var result: [String:Any] = ["type":"tool_result","tool_use_id":"read\(i)","content":read.0]
                if read.1 == .truncated { result["truncated"] = true }
                if read.1 == .unknown { result["content"] = "1→" + read.0 }
                if read.1 == .multiple { result["content"] = [["type":"text","text":read.0],["type":"text","text":"other file"]] }
                if read.1 == .failed { result["is_error"] = true }
                rows.append(claude("result\(i)","user",[result]))
            }
            if secondTurn { rows.append(claude("second-prompt", "user", "Second task")) }
            rows.append(claude("final","assistant",[["type":"text","text":"Synthetic output"]],final:true,session:secondSession ? "other-session" : "session"))
        case .gemini:
            rows = [["sessionId":"session"],["id":"prompt","type":"user","timestamp":timestamp,"content":"Synthetic task"]]
            for (i, read) in reads.enumerated() {
                var args: [String:Any] = ["file_path":path]
                if read.1 == .partial { args["offset"] = 0; args["limit"] = 20 }
                var call: [String:Any] = ["id":"read\(i)","name":"read_file","args":args,"status":read.1 == .failed ? "error" : "success", "result":[["functionResponse":["response":["output":read.0]]]]]
                if read.1 == .truncated { call["truncated"] = true }
                if read.1 == .unknown { call["result"] = ["unknown":["content":read.0]] }
                if read.1 == .multiple { call["result"] = [["functionResponse":["response":["output":read.0]]],["functionResponse":["response":["output":"other file"]]]] }
                rows.append(["id":"call\(i)","type":"gemini","toolCalls":[call]])
            }
            if secondSession { rows.append(["sessionId":"other-session"]) }
            if secondTurn { rows.append(["id":"second-prompt","type":"user","timestamp":timestamp,"content":"Second task"]) }
            rows.append(["id":"final","type":"gemini","timestamp":timestamp,"content":"Synthetic output","tokens":["total":10]])
        }
        let data = try rows.reduce(into:Data()) { $0.append(try JSONSerialization.data(withJSONObject:$1)); $0.append(10) }
        switch agent {
        case .codex: return try CodexRunHistoryAdapter.parse(data,sourceLog:"/fixture/log",skill:skill,versions:versions)
        case .claude: return try ClaudeRunHistoryAdapter.parse(data,sourceLog:"/fixture/log",skill:skill,versions:versions)
        case .gemini: return try GeminiRunHistoryAdapter.parse(data,sourceLog:"/fixture/log",skill:skill,versions:versions)
        }
    }
    func testEvidenceDoesNotCrossTurnsOrFiles() throws {
        let version = SkillVersion(skillID:"fixture",number:1,content:long,note:"fixture")
        for agent in AgentKind.allCases {
            XCTAssertTrue(try parse(agent,reads:[(long,.full)],versions:[version],secondTurn:true).isEmpty,agent.rawValue)
            XCTAssertTrue(try parse(agent,reads:[(long,.full)],versions:[version],wrongFile:true).isEmpty,agent.rawValue)
        }
    }
    func testEveryHostMatchesCompleteBodiesAndRetainsUnknownRuns() throws {
        let v1 = SkillVersion(skillID:"fixture",number:1,content:long,note:"fixture")
        let v2 = SkillVersion(skillID:"fixture",number:2,content:short,note:"fixture")
        for agent in AgentKind.allCases {
            let exact = try XCTUnwrap(parse(agent,reads:[(long,.full)],versions:[v2,v1]).first)
            XCTAssertEqual(exact.versionID,v1.id,agent.rawValue)
            XCTAssertEqual(exact.effectiveVersionAttribution.kind,.matchingContent)
            let unsaved = try XCTUnwrap(parse(agent,reads:[(long,.full)],versions:[v2]).first)
            XCTAssertNil(unsaved.versionID); XCTAssertEqual(unsaved.effectiveVersionAttribution.reason,.noMatchingVersion)
            for (form, reason) in [(Form.partial,RunVersionUnknownReason.incompleteRead),(.truncated,.incompleteRead),(.unknown,.unsupportedReadFormat),(.multiple,.unsupportedReadFormat)] {
                let run = try XCTUnwrap(parse(agent,reads:[(long,form)],versions:[v1]).first)
                XCTAssertNil(run.versionID,agent.rawValue); XCTAssertEqual(run.effectiveVersionAttribution.reason,reason,agent.rawValue)
            }
            XCTAssertTrue(try parse(agent,reads:[(long,.failed)],versions:[v1]).isEmpty)
            XCTAssertTrue(try parse(agent,reads:[(long,.full)],versions:[v1],secondSession:true).isEmpty)
        }
    }
    func testEveryHostCombinesAllReadsWithoutLastReadWins() throws {
        let v1 = SkillVersion(skillID:"fixture",number:1,content:long,note:"fixture")
        let v2 = SkillVersion(skillID:"fixture",number:2,content:short,note:"fixture")
        let restored = SkillVersion(skillID:"fixture",number:3,content:long,note:"fixture")
        for agent in AgentKind.allCases {
            for reads: [(String,Form)] in [[(long,.full),(long,.full),(short,.partial)],[(short,.partial),(long,.full)]] {
                let run = try XCTUnwrap(parse(agent,reads:reads,versions:[v2,v1]).first)
                XCTAssertEqual(run.versionID,v1.id); XCTAssertEqual(run.readEvidence?.completeBodySHA256.count,1)
            }
            let conflict = try XCTUnwrap(parse(agent,reads:[(long,.full),(short,.full)],versions:[v2,v1]).first)
            XCTAssertNil(conflict.versionID); XCTAssertEqual(conflict.effectiveVersionAttribution.reason,.conflictingReadEvidence)
            let ambiguous = try XCTUnwrap(parse(agent,reads:[(long,.full)],versions:[restored,v2,v1]).first)
            XCTAssertNil(ambiguous.versionID); XCTAssertEqual(Set(ambiguous.effectiveVersionAttribution.candidateVersionIDs),[v1.id,restored.id])
        }
    }
}
