import XCTest
@testable import SkillStudioCore

final class ChunkedTranslationTests: XCTestCase {
    func testSplittingPreservesEveryByteAndCodeFence() {
        for newline in ["\n", "\r\n"] {
            let source = ["# Title", "", "Text with 日本語 and 👨‍👩‍👧‍👦.", "```swift", "let example = 1", "```", "", "~~~sh", "echo hello", "~~~", "Tail", ""].joined(separator: newline)
            let fragments = TranslationFragment.split(source, targetBytes: 30)
            XCTAssertEqual(fragments.map(\.source).joined(), source)
            XCTAssertEqual(fragments.filter { !$0.needsTranslation && !$0.body.isEmpty }.count, 2)
            XCTAssertTrue(fragments.contains { $0.source.contains("let example = 1") && !$0.needsTranslation })
        }
        let unclosed = "Heading\n```python\nprint('hello')"
        XCTAssertEqual(TranslationFragment.split(unclosed).map(\.source).joined(), unclosed)
        XCTAssertFalse(TranslationFragment.split(unclosed).last!.needsTranslation)
    }

    func testLongTranslationBoundedConcurrencyOrderingAndProgress() async throws {
        let source = (0..<25).map { "## Section \($0)\n" + String(repeating: "Hello world. ", count: 80) + "\n\n" }.joined()
            + "```sh\necho Hello world.\n```\n"
        let base = RecordingTranslator(), tracker = ProgressRecorder()
        let result = try await ChunkedTranslationService(base: base, maxConcurrentRequests: 2).translate(.init(content: source, language: .japanese)) { await tracker.record($0) }
        XCTAssertEqual(result, source.replacingOccurrences(of: "Hello world.", with: "こんにちは世界。")
            .replacingOccurrences(of: "echo こんにちは世界。", with: "echo Hello world."))
        let sizes = await base.sizes, maxRunning = await base.maxRunning, updates = await tracker.updates
        XCTAssertGreaterThan(sizes.count, 2)
        XCTAssertTrue(sizes.allSatisfy { $0 <= 5_000 })
        XCTAssertEqual(maxRunning, 2)
        XCTAssertEqual(updates.map(\.completed), Array(0...sizes.count))
        XCTAssertEqual(updates.last?.total, sizes.count)
    }

    @MainActor func testFailureStopsSessionAndNeverPublishesPartialTranslation() async throws {
        let session = TranslationSession()
        let source = String(repeating: "Hello world.\n", count: 900)
        session.translate(.init(content: source, language: .japanese), using: ChunkedTranslationService(base: RecordingTranslator(fail: true)))
        for _ in 0..<200 where session.isTranslating { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(session.isTranslating); XCTAssertNotNil(session.error); XCTAssertNil(session.translation)
        session.translate(.init(content: "Hello world.", language: .japanese), using: ChunkedTranslationService(base: RecordingTranslator()))
        for _ in 0..<200 where session.isTranslating { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(session.translation, "こんにちは世界。"); XCTAssertNil(session.error)
    }

    func testCancellationStopsAllInFlightSections() async throws {
        let base = RecordingTranslator(slow: true)
        let task = Task { try await ChunkedTranslationService(base: base, maxConcurrentRequests: 2).translate(.init(content: String(repeating: "Hello world.\n", count: 1500), language: .japanese)) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let running = await base.running, calls = await base.sizes.count
        XCTAssertEqual(running, 0); XCTAssertEqual(calls, 2)
    }

    func testConfiguredConcurrencyStartsWholeWindowBeforeAnySectionFinishes() async throws {
        // Each line is one section. Hold responses so the test proves overlap, not just task creation.
        let source = (0..<36).map { "Section \($0) " + String(repeating: "a", count: 3_000) + "\n" }.joined()
        // Stay within the document's 100 KB input limit.
        let request = SkillTranslationRequest(content: String(source.prefix(90_000)), language: .japanese)
        for (configured, expected) in [(0, 1), (4, 4), (18, 18), (100, 18)] {
            let base = GatedTranslator(), tracker = ProgressRecorder()
            let task = Task { try await ChunkedTranslationService(base: base, maxConcurrentRequests: configured).translate(request) { await tracker.record($0) } }
            for _ in 0..<200 {
                if await base.started >= expected { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let started = await base.started, peak = await base.peak, before = await tracker.updates
            XCTAssertEqual(started, expected)
            XCTAssertEqual(peak, expected)
            XCTAssertEqual(before.map(\.completed), [0])
            await base.release()
            let result = try await task.value
            XCTAssertEqual(result, request.content)
            let updates = await tracker.updates
            XCTAssertEqual(updates.map(\.completed), Array(0...updates.last!.total))
        }
    }

    func testCancellationStopsEighteenInFlightSections() async throws {
        let base = RecordingTranslator(slow: true)
        let source = (0..<18).map { "Section \($0) " + String(repeating: "a", count: 3_000) + "\n" }.joined()
        let task = Task { try await ChunkedTranslationService(base: base).translate(.init(content: source, language: .japanese)) }
        for _ in 0..<200 {
            if await base.running == 18 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let peak = await base.maxRunning
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let running = await base.running
        XCTAssertEqual(peak, 18); XCTAssertEqual(running, 0)
    }

    func testLiveLongDocumentWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["SKILL_STUDIO_LIVE_DOCUMENT"] else {
            throw XCTSkip("Opt-in test: explicitly specify the document authorized for translation.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path)), content = try XCTUnwrap(String(data: data, encoding: .utf8))
        let base = CLITranslationService(executable: CodexExecutable.resolve()), tracker = ProgressRecorder()
        let result = try await ChunkedTranslationService(base: base).translate(.init(content: content, language: .japanese)) {
            await tracker.record($0)
            print("Translation sections: \($0.completed)/\($0.total)")
        }
        XCTAssertTrue(result.contains("name:")); XCTAssertTrue(result.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) })
        XCTAssertGreaterThan(result.utf8.count, content.utf8.count / 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        let progress = await tracker.updates.last
        XCTAssertGreaterThan(progress?.total ?? 0, 1); XCTAssertEqual(progress?.completed, progress?.total)
    }
}

private actor ProgressRecorder {
    var updates: [TranslationProgress] = []
    func record(_ progress: TranslationProgress) { updates.append(progress) }
}

private actor GatedTranslator: SkillTranslationService {
    var started = 0, running = 0, peak = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func translate(_ request: SkillTranslationRequest) async throws -> String {
        started += 1; running += 1; peak = max(peak, running)
        defer { running -= 1 }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        return request.content
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RecordingTranslator: SkillTranslationService {
    var sizes: [Int] = [], running = 0, maxRunning = 0
    let fail: Bool, slow: Bool
    init(fail: Bool = false, slow: Bool = false) { self.fail = fail; self.slow = slow }
    func translate(_ request: SkillTranslationRequest) async throws -> String {
        sizes.append(request.content.utf8.count); running += 1; maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        let index = sizes.count
        try await Task.sleep(nanoseconds: slow ? 5_000_000_000 : index % 2 == 1 ? 30_000_000 : 5_000_000)
        if fail, index == 2 { throw TranslationError.timedOut }
        return request.content.replacingOccurrences(of: "Hello world.", with: "こんにちは世界。")
    }
}
