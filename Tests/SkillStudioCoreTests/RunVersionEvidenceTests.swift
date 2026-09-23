import XCTest
@testable import SkillStudioCore

final class RunVersionEvidenceTests: XCTestCase {
    private let path = "/fixture/skills/example/SKILL.md"
    private func version(_ body: String, _ number: Int = 1, skill: String = "fixture") -> SkillVersion {
        .init(skillID: skill, number: number, content: body, note: "fixture")
    }
    func testStrictBytesScopeEmptyAndOrderIndependence() {
        let full = "# Example\nKeep the response short.\nInclude acceptance criteria.\n"
        let short = "# Example\nKeep the response short.\n"
        let v1 = version(full), v2 = version(short, 2), foreign = version(full, skill: "another")
        for versions in [[v2, v1, foreign], [foreign, v1, v2]] {
            let result = RunVersionResolver.resolve([.complete(full)], skillID: "fixture", versions: versions)
            XCTAssertEqual(result.versionID, v1.id); XCTAssertEqual(result.attribution.kind, .matchingContent)
            XCTAssertEqual(result.attribution.candidateVersionIDs, [v1.id])
        }
        for versions in [[v2], [foreign], []] {
            let result = RunVersionResolver.resolve([.complete(full)], skillID: "fixture", versions: versions)
            XCTAssertNil(result.versionID); XCTAssertEqual(result.attribution.reason, .noMatchingVersion)
        }
        for changed in [full + " ", full.replacingOccurrences(of: "\n", with: "\r\n"), String(full.dropLast())] {
            XCTAssertNil(RunVersionResolver.resolve([.complete(changed)], skillID: "fixture", versions: [v1]).versionID)
        }
        let composed = version("é")
        XCTAssertEqual("é", "e\u{301}") // Swift String equality is intentionally NOT the resolver's equality.
        XCTAssertNil(RunVersionResolver.resolve([.complete("e\u{301}")], skillID: "fixture", versions: [composed]).versionID)
        XCTAssertNil(RunVersionResolver.resolve([.complete("")], skillID: "fixture", versions: [version("")]).versionID)
    }
    func testDuplicateRevisionsAndMultipleReads() {
        let v1 = version("A"), v2 = version("B", 2), v3 = version("A", 3)
        let repeated = RunVersionResolver.resolve([.complete("A"), .complete("A"), .incomplete], skillID: "fixture", versions: [v3,v2,v1])
        XCTAssertNil(repeated.versionID); XCTAssertEqual(repeated.attribution.kind, .matchingContent)
        XCTAssertEqual(repeated.attribution.reason, .ambiguousMatchingVersions)
        XCTAssertEqual(Set(repeated.attribution.candidateVersionIDs), [v1.id,v3.id])
        XCTAssertEqual(repeated.reads.completeBodySHA256.count, 1)
        let conflicting = RunVersionResolver.resolve([.complete("A"), .complete("B")], skillID: "fixture", versions: [v1,v2])
        XCTAssertNil(conflicting.versionID); XCTAssertEqual(conflicting.attribution.reason, .conflictingReadEvidence)
        XCTAssertEqual(conflicting.reads.completeBodySHA256.count, 2)
    }
    private func assertRead(_ read: HistoricalSkillRead, body: String = "# Example\n", reason: RunVersionUnknownReason? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let result = RunVersionResolver.resolve([read], skillID: "fixture", versions: [version(body)])
        XCTAssertEqual(result.attribution.kind, reason == nil ? .matchingContent : .unknown, file: file, line: line)
        XCTAssertEqual(result.attribution.reason, reason, file: file, line: line)
    }
    func testCodexExtractorRejectsPartialAmbiguousAndAggregateOutput() {
        let body = "# Example\n"
        var read: [String:Any] = ["type":"read", "path":path, "cmd":"cat '\(path)'"]
        var item: [String:Any] = ["parsed_cmd":[read], "stdout":body, "stderr":""]
        func extract() -> HistoricalSkillRead { HistoryReadExtraction.codex(item:item, read:read, target:path, cwd:"/fixture") }
        assertRead(extract())
        for command in ["head -n 20 \(path)", "tail -n 20 \(path)", "sed -n '1,20p' \(path)"] {
            item["command"] = command; assertRead(extract(), reason:.incompleteRead)
        }
        for command in ["cat \(path) /fixture/other", "cat \(path) | cat", "echo hello; cat \(path)", "cat $(touch /fixture/NEVER_EXECUTE)", "cat -n \(path)", "cat /fixture/other"] {
            item["command"] = command; assertRead(extract(), reason:.unsupportedReadFormat)
        }
        item.removeValue(forKey:"command")
        item["parsed_cmd"] = [read,read]; assertRead(extract(), reason:.unsupportedReadFormat)
        item["parsed_cmd"] = [read]
        item["stdout"] = ""; item["aggregated_output"] = body; assertRead(extract(), reason:.unsupportedReadFormat)
        item["stdout"] = body; item["stderr"] = "explanation"; assertRead(extract(), reason:.unsupportedReadFormat)
        item["stderr"] = ""; item["truncated"] = true; assertRead(extract(), reason:.incompleteRead)
        item.removeValue(forKey:"truncated")
        read["limit"] = 10; assertRead(extract(), reason:.incompleteRead)
    }
    func testClaudeAndGeminiRawAndKnownContainerForms() {
        let body = "# Example\n"
        assertRead(HistoryReadExtraction.claude(input:["file_path":path], result:["content":body]))
        assertRead(HistoryReadExtraction.claude(input:[:], result:["content":[["type":"text","text":body]]]))
        assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":body]))
        assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":[["functionResponse":["response":["output":body]]]]]))
        for key in ["offset","limit","start_line","end_line"] {
            assertRead(HistoryReadExtraction.claude(input:[key:0], result:["content":body]), reason:.incompleteRead)
            assertRead(HistoryReadExtraction.gemini(args:[key:0], call:["result":body]), reason:.incompleteRead)
        }
        for text in ["1→# Example\n", "File: SKILL.md\n# Example\n", "<unknown># Example</unknown>"] {
            assertRead(HistoryReadExtraction.claude(input:[:], result:["content":text]), body:text, reason:.unsupportedReadFormat)
            assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":text]), body:text, reason:.unsupportedReadFormat)
        }
        assertRead(HistoryReadExtraction.claude(input:[:], result:["content":body,"truncated":true]), reason:.incompleteRead)
        assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":body,"truncated":true]), reason:.incompleteRead)
        assertRead(HistoryReadExtraction.claude(input:[:], result:["content":[["type":"text","text":body],["type":"text","text":body]]]), reason:.unsupportedReadFormat)
        assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":["mystery":["output":body]]]), reason:.unsupportedReadFormat)
        assertRead(HistoryReadExtraction.gemini(args:[:], call:["result":[["functionResponse":["response":["output":body,"stderr":"warning"]]]]]), reason:.unsupportedReadFormat)
    }
}
