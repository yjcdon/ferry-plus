import CryptoKit
import Foundation
import os
import Testing
@testable import DownloadKit

private let kilobyte = 1 << 10
private let megabyte = 1 << 20

@Suite struct DownloadEngineTests {
    @Test func downloadsSegmentsInParallelAndMatchesSource() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("movie.mp4", size: 3 * megabyte)
        let engine = fixture.makeEngine()
        let events = engine.events()
        let collector = Task {
            var states: [DownloadState] = []
            for await case .stateChanged(let snapshot) in events {
                states.append(snapshot.state)
                if case .completed = snapshot.state { break }
            }
            return states
        }

        let request = fixture.request("movie.mp4")
        try await engine.enqueue(request)
        let location = try await engine.waitForCompletion(of: "movie.mp4")

        #expect(location == fixture.downloadsDirectory.appendingPathComponent("movie.mp4"))
        #expect(fixture.contents("movie.mp4") == data)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        #expect(try fixture.savedRecords().map(\.completedURL) == [location])

        let log = fixture.server.log
        #expect(log.count == 12)
        #expect(log.allSatisfy { $0.headers["Cookie"] == "BDUSS=test" && $0.headers["User-Agent"] == "FerryTests" })
        #expect(log.allSatisfy { $0.headers["Accept-Encoding"] == "identity" })
        let ranges = log.compactMap(\.range).map { $0.first...$0.last! }.sorted { $0.lowerBound < $1.lowerBound }
        #expect(ranges.count == 12)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == Int64(data.count - 1))
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound })
        #expect(fixture.server.maxActive <= 4)
        #expect(fixture.source.resolveCount == 1)

        let states = await collector.value
        #expect(states.first == .queued)
        #expect(states.contains(.running))
        #expect(states.last == .completed(location))
    }

    /// 大逻辑分片在共享预算下拆小请求，连续 offset 不重叠、不跳过末尾。
    @Test func sharedBudgetSplitsRangesAndPreservesOffsets() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("budget.bin", size: megabyte + 17)
        var configuration = DownloadConfiguration.test(connections: 1)
        configuration.segmentSize = .fixed(Int64(megabyte))
        let budget = try TransferBudget(maximumConnections: 1)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: configuration, session: fixture.session, transferBudget: budget)
        try await engine.enqueue(fixture.request("budget.bin"))
        _ = try await engine.waitForCompletion(of: "budget.bin")
        let ranges = fixture.server.log.compactMap(\.range)
        #expect(ranges.count == 5)
        #expect(ranges.map(\.first) == [0, 262144, 524288, 786432, 1048576])
        #expect(ranges.map { $0.last } == [262143, 524287, 786431, 1048575, 1048592])
        #expect(fixture.contents("budget.bin") == data)
        #expect(fixture.server.maxActive == 1)
        #expect(await budget.snapshot().activeConnections == 0)
        await engine.shutdown()
    }

    /// 未注入预算时，已有大分片请求数量和同步流式行为保持不变。
    @Test func nilSharedBudgetKeepsOriginalRequestShape() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("legacy.bin", size: megabyte)
        var configuration = DownloadConfiguration.test(connections: 1)
        configuration.segmentSize = .fixed(Int64(megabyte))
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: configuration, session: fixture.session, transferBudget: nil)
        try await engine.enqueue(fixture.request("legacy.bin"))
        _ = try await engine.waitForCompletion(of: "legacy.bin")
        #expect(fixture.server.log.count == 1)
        #expect(fixture.server.log.first?.headers["Range"] == "bytes=0-1048575")
        #expect(fixture.contents("legacy.bin") == data)
        await engine.shutdown()
    }

    /// 暂停同时撤销排队和在途请求；共享许可须全部归还，后续消费者才能继续。
    @Test func sharedBudgetCancellationReleasesActiveAndWaitingPermits() async throws {
        let fixture = Fixture()
        fixture.addFile("cancel-budget.bin", size: megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        defer { fixture.server.setStall(after: nil) }
        let budget = try TransferBudget(maximumConnections: 1)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: .test(connections: 2), session: fixture.session, transferBudget: budget)
        try await engine.enqueue(fixture.request("cancel-budget.bin"))
        try await waitUntil("one active and one waiting shared permit") {
            let state = await budget.snapshot()
            return state.activeConnections == 1 && state.waitingConnections == 1
        }
        await engine.pause(id: "cancel-budget.bin")
        let state = await budget.snapshot()
        #expect(state.activeConnections == 0)
        #expect(state.waitingConnections == 0)
        try await waitUntil("cancelled server request to finish") { fixture.server.activeRequests == 0 }
        let lease = try await budget.acquire()
        await budget.release(lease)
        await engine.shutdown()
    }

    /// 取消发生在字节额度等待时不能启动 HTTP，也不能遗留速率定时器。
    @Test func sharedBudgetCancellationEndsRateWaitBeforeRequest() async throws {
        let fixture = Fixture()
        fixture.addFile("rate-wait.bin", size: megabyte)
        let budget = try TransferBudget(maximumConnections: 1, downloadBytesPerSecond: 1)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: .test(connections: 1), session: fixture.session, transferBudget: budget)
        try await engine.enqueue(fixture.request("rate-wait.bin"))
        try await waitUntil("download byte quota wait") { await budget.snapshot().waitingDownloadBuffers == 1 }
        await engine.pause(id: "rate-wait.bin")
        let state = await budget.snapshot()
        #expect(state.activeConnections == 0)
        #expect(state.waitingDownloadBuffers == 0)
        #expect(state.activeRateTimers == 0)
        #expect(fixture.server.log.isEmpty)
        await engine.shutdown()
    }

    /// 请求发出前必须付清当前范围额度，令牌桶初始突发之外的字节确实等待。
    @Test func sharedBudgetWaitsForDownloadRateBeforeReceivingRange() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("rate.bin", size: 64 * kilobyte)
        let budget = try TransferBudget(maximumConnections: 1, downloadBytesPerSecond: 256 * 1024)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: .test(connections: 1), session: fixture.session, transferBudget: budget)
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.enqueue(fixture.request("rate.bin"))
        _ = try await engine.waitForCompletion(of: "rate.bin")
        #expect(start.duration(to: clock.now) >= .milliseconds(80))
        #expect(fixture.contents("rate.bin") == data)
        #expect(await budget.snapshot().waitingDownloadBuffers == 0)
        #expect(await budget.snapshot().activeConnections == 0)
        await engine.shutdown()
    }

    /// 非 Range 流按共享速率等待，EOF 后排空缓冲再完成并归还连接与限速等待。
    @Test func sharedBudgetNonRangeLimitsBytesAndDrainsEOF() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("no-range.bin", size: 128 * kilobyte)
        fixture.server.setSupportsRanges(false)
        let budget = try TransferBudget(maximumConnections: 1, downloadBytesPerSecond: 128 * 1024)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: fixture.source,
            configuration: .test(connections: 1), session: fixture.session, transferBudget: budget)
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.enqueue(fixture.request("no-range.bin", knownSize: false))
        _ = try await engine.waitForCompletion(of: "no-range.bin")
        #expect(start.duration(to: clock.now) >= .milliseconds(700))
        #expect(fixture.contents("no-range.bin") == data)
        #expect(await engine.snapshot(id: "no-range.bin")?.totalBytes == Int64(data.count))
        #expect(fixture.server.log.count == 2)
        #expect(fixture.server.log.last?.headers["Range"] == nil)
        let state = await budget.snapshot()
        #expect(state.activeConnections == 0)
        #expect(state.waitingConnections == 0)
        #expect(state.waitingDownloadBuffers == 0)
        #expect(state.activeRateTimers == 0)
        await engine.shutdown()
    }

    @Test func probesSizeWhenUnknown() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte + 123)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin", knownSize: false))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(await engine.snapshot(id: "a.bin")?.totalBytes == Int64(data.count))
        let log = fixture.server.log
        #expect(log.first?.headers["Range"] == "bytes=0-0")
        #expect(log.count == 1 + 5)
    }

    @Test func respectsConcurrencyLimits() async throws {
        let fixture = Fixture()
        let names = (0..<5).map { "file\($0).bin" }
        let files = names.map { fixture.addFile($0, size: megabyte) }
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(files: 2, connections: 3))

        for name in names {
            try await engine.enqueue(fixture.request(name))
        }
        try await waitUntil("6 active requests") { fixture.server.activeRequests == 6 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.server.maxActive == 6)
        #expect(fixture.server.maxActiveFiles == 2)
        #expect(await engine.snapshots().map(\.state) == [.running, .running, .queued, .queued, .queued])

        var configuration = DownloadConfiguration.test(files: 3, connections: 3)
        await engine.updateConfiguration(configuration)
        try await waitUntil("9 active requests") { fixture.server.activeRequests == 9 }
        #expect(await engine.snapshots().map(\.state) == [.running, .running, .running, .queued, .queued])

        configuration.maxConcurrentFiles = 2
        await engine.updateConfiguration(configuration)
        fixture.server.setStall(after: nil)
        for (name, data) in zip(names, files) {
            _ = try await engine.waitForCompletion(of: name)
            #expect(fixture.contents(name) == data)
        }
        #expect(fixture.server.maxActive == 9)
        #expect(fixture.server.maxActiveFiles == 3)
    }

    @Test func raisingConnectionsAppliesToRunningDownload() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("1 active request") { fixture.server.activeRequests == 1 }

        await engine.updateConfiguration(.test(connections: 3))
        // 重配置先保存并取消旧请求，再由新预算领取分片，用满 3 个连接。
        fixture.server.setStallRule { $0.range?.first == 0 ? nil : 64 * kilobyte }
        try await waitUntil("3 active requests") { fixture.server.activeRequests == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.server.maxActive == 3)

        fixture.server.setStall(after: nil)
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
    }

    /// 两种预算都合法，但旧文件数和新连接数不能在收尾期间相乘。
    @Test(arguments: [true, false])
    func reconfigurationDrainsWorkersBeforeApplyingNewBudget(raisingConnections: Bool) async throws {
        let fixture = Fixture()
        let names = (0..<10).map { "file\($0).bin" }
        let data = names.map { fixture.addFile($0, size: 3 * megabyte) }
        fixture.server.setStall(after: 64 * kilobyte)
        let source = GatedSource(fixture.source, gating: Set(names))
        defer {
            source.open()
            fixture.server.setStall(after: nil)
        }
        let initial = DownloadConfiguration.test(files: raisingConnections ? 10 : 2,
                                                 connections: raisingConnections ? 1 : 10)
        let updated = DownloadConfiguration.test(files: raisingConnections ? 2 : 10,
                                                 connections: raisingConnections ? 10 : 1)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: initial, session: fixture.session)
        for name in names {
            var request = fixture.request(name)
            // 模拟旧任务曾保存较高的每文件连接数；实际并发仍应受当前全局配置约束。
            request.connections = 10
            try await engine.enqueue(request)
        }
        let firstWorkers = Array(names.prefix(initial.maxConcurrentFiles))
        try await waitUntil("initial workers to wait for their links") {
            firstWorkers.allSatisfy(source.hasEntered)
        }
        let update = Task { await engine.updateConfiguration(updated) }
        try await waitUntil("old workers to be cancelled before applying the budget") {
            firstWorkers.allSatisfy(source.wasCancelled)
        }
        #expect(fixture.server.log.isEmpty)
        // 相同预算下的后续普通设置使用最新值，但不能解开正在收尾的屏障。
        var latest = updated
        latest.maxRetries = 1
        await engine.updateConfiguration(latest)
        #expect(fixture.server.log.isEmpty)
        source.open()
        await update.value
        let expectedConnections = updated.maxConcurrentFiles * updated.segmentsPerFile
        try await waitUntil("new budget to fill its slots") { fixture.server.activeRequests == expectedConnections }
        #expect(await engine.snapshots().filter { $0.state == .running }.count == updated.maxConcurrentFiles)
        #expect(fixture.server.maxActive == expectedConnections)
        fixture.server.setStall(after: nil)
        for (name, expected) in zip(names, data) {
            _ = try await engine.waitForCompletion(of: name)
            #expect(fixture.contents(name) == expected)
        }
        await engine.shutdown()
    }

    /// 调整预算不得把用户已经暂停的下载重新排队。
    @Test func reconfigurationPreservesExplicitPause() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        defer { fixture.server.setStall(after: nil) }
        let engine = fixture.makeEngine(.test(files: 1, connections: 1))
        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("file to receive bytes") {
            (await engine.snapshot(id: "a.bin")?.receivedBytes ?? 0) > 0
        }
        await engine.pause(id: "a.bin")
        let saved = try #require(try fixture.savedRecords().first)
        await engine.updateConfiguration(.test(files: 2, connections: 10))
        #expect(await engine.snapshot(id: "a.bin")?.state == .paused)
        #expect(try fixture.savedRecords().first?.receivedBytes == saved.receivedBytes)
        #expect(try fixture.savedRecords().first?.isPaused == true)
        await engine.shutdown()
    }

    /// 另一来源维持最大连接数时，单家升降仍要替换旧请求，同时保留手动暂停。
    @Test(arguments: [true, false])
    func perSourceConnectionsChangeWithUnchangedGlobalMaximum(raising: Bool) async throws {
        let fixture = Fixture()
        let first = fixture.addFile("baidu.bin", size: 8 * megabyte)
        let second = fixture.addFile("quark.bin", size: 8 * megabyte)
        fixture.addFile("paused.bin", size: megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        defer { fixture.server.setStall(after: nil) }
        let configuration = DownloadConfiguration.test(files: 3, connections: 3)
        let engine = fixture.makeEngine(configuration)
        var baidu = fixture.request("baidu.bin")
        baidu.connections = raising ? 1 : 3
        var quark = fixture.request("quark.bin")
        quark.connections = 3
        var paused = fixture.request("paused.bin")
        paused.connections = 1
        try await engine.enqueue(paused)
        await engine.pause(id: paused.id)
        try await engine.enqueue(baidu)
        try await engine.enqueue(quark)
        try await waitUntil("initial per-source connections") {
            fixture.server.activeRequests == (raising ? 4 : 6)
        }
        await engine.updateConfiguration(configuration, connections: [baidu.id: raising ? 3 : 1, quark.id: 3, paused.id: 2])
        try await waitUntil("updated per-source connections") {
            fixture.server.activeRequests == (raising ? 6 : 4)
        }
        #expect(await engine.snapshot(id: paused.id)?.state == .paused)
        let records = try fixture.savedRecords()
        #expect(records.first { $0.request.id == baidu.id }?.request.connections == (raising ? 3 : 1))
        #expect(records.first { $0.request.id == quark.id }?.request.connections == 3)
        #expect(records.first { $0.request.id == paused.id }?.request.connections == 2)
        #expect(records.first { $0.request.id == paused.id }?.isPaused == true)
        #expect(fixture.server.maxActive <= 6)
        fixture.server.setStall(after: nil)
        _ = try await engine.waitForCompletion(of: baidu.id)
        _ = try await engine.waitForCompletion(of: quark.id)
        #expect(fixture.contents(baidu.id) == first)
        #expect(fixture.contents(quark.id) == second)
        await engine.shutdown()
    }

    /// 重启使用当前来源配置，不能重新采用旧请求中的连接数；暂停标记不变。
    @Test func restoreUpdatesPerSourceConnectionsWithoutResumingPausedFile() async throws {
        let fixture = Fixture()
        fixture.addFile("paused.bin", size: megabyte)
        let first = fixture.makeEngine()
        var request = fixture.request("paused.bin")
        request.connections = 3
        try await first.enqueue(request)
        await first.pause(id: request.id)
        await first.shutdown()
        let second = fixture.makeEngine()
        let restored = try await second.restore(connections: [request.id: 1])
        #expect(restored.first?.state == .paused)
        #expect(try fixture.savedRecords().first?.request.connections == 1)
        #expect(try fixture.savedRecords().first?.isPaused == true)
        await second.shutdown()
    }

    /// 文件请求跨 actor 迟到时也采用已更新的来源配置，不能恢复请求中的旧预算。
    @Test func latestConnectionsApplyToRequestEnqueuedAfterConfigurationUpdate() async throws {
        let fixture = Fixture()
        fixture.addFile("late.bin", size: 3 * megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        defer { fixture.server.setStall(after: nil) }
        let configuration = DownloadConfiguration.test(files: 1, connections: 3)
        let engine = fixture.makeEngine(configuration)
        var request = fixture.request("late.bin")
        request.connections = 3
        await engine.updateConfiguration(configuration, connections: [request.id: 1])
        try await engine.enqueue(request)
        try await waitUntil("latest connection override to take effect") { fixture.server.activeRequests == 1 }
        await engine.pause(id: request.id)
        #expect(try fixture.savedRecords().first?.request.connections == 1)
        #expect(fixture.server.maxActive == 1)
        await engine.shutdown()
    }

    /// 快速降后升采用最后配置，收尾期间新加入的文件不能绕过屏障或带回旧覆盖值。
    @Test func rapidPerSourceUpdatesKeepLatestConnectionsForNewEnqueues() async throws {
        let fixture = Fixture()
        fixture.addFile("old.bin", size: 3 * megabyte)
        fixture.addFile("new.bin", size: 3 * megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        let source = GatedSource(fixture.source, gating: ["old.bin"])
        defer { source.open(); fixture.server.setStall(after: nil) }
        let configuration = DownloadConfiguration.test(files: 2, connections: 3)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: configuration, session: fixture.session)
        var old = fixture.request("old.bin")
        old.connections = 3
        try await engine.enqueue(old)
        try await waitUntil("original source lookup") { source.hasEntered(old.id) }
        let decrease = Task { [oldID = old.id] in
            await engine.updateConfiguration(configuration, connections: [oldID: 1, "new.bin": 1])
        }
        try await waitUntil("old worker cancellation") { source.wasCancelled(old.id) }
        var new = fixture.request("new.bin")
        new.connections = 3
        try await engine.enqueue(new)
        #expect(fixture.server.log.isEmpty)
        let increase = Task { [oldID = old.id, newID = new.id] in
            await engine.updateConfiguration(configuration, connections: [oldID: 3, newID: 2])
        }
        source.open()
        await decrease.value
        await increase.value
        try await waitUntil("latest mixed connection counts") { fixture.server.activeRequests == 5 }
        let records = try fixture.savedRecords()
        #expect(records.first { $0.request.id == old.id }?.request.connections == 3)
        #expect(records.first { $0.request.id == new.id }?.request.connections == 2)
        #expect(fixture.server.maxActive <= 6)
        await engine.shutdown()
    }

    @Test func retriesTransientErrors() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setFaultRule { _, index in
            switch index {
            case 0: .disconnect(afterBytes: 100 * kilobyte)
            case 1: .status(500)
            case 2: .status(503)
            default: nil
            }
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        let interrupted = try #require(log.first?.range?.first)
        #expect(log.contains { $0.range?.first == interrupted + Int64(100 * kilobyte) })
        #expect(fixture.source.resolveCount == 1)
    }

    @Test func refreshesExpiredLink() async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.expire(token: "old")
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 2)
        let log = fixture.server.log
        #expect(log.count { $0.token == "new" } == 4)
        #expect(log.allSatisfy { $0.headers["Cookie"] == "BDUSS=test" })
    }

    /// 旧地址已产生部分字节后失效，刷新地址只请求尚缺范围，不从零重下。
    @Test func expiredLinkAfterPartialBytesRefreshesAtSavedOffset() async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setFaultRule { [weak server = fixture.server] request, index in
            if index == 0, request.token == "old" {
                // 首响应已被服务端接受，之后的新请求才会被判定过期。
                server?.expire(token: "old")
                return .disconnect(afterBytes: 64 * kilobyte)
            }
            return nil
        }
        defer { fixture.server.setFaultRule(nil) }
        let engine = fixture.makeEngine(.test(files: 1, connections: 1))
        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 2)
        let log = fixture.server.log
        #expect(log.first?.token == "old")
        #expect(log.first?.range?.first == 0)
        #expect(log.contains { $0.token == "old" && $0.range?.first == Int64(64 * kilobyte) })
        #expect(log.first { $0.token == "new" }?.range?.first == Int64(64 * kilobyte))
        #expect(log.dropFirst().allSatisfy { ($0.range?.first ?? 0) >= Int64(64 * kilobyte) })
        await engine.shutdown()
    }

    /// 即使长度相同，续传的实体标识变化也不能把新内容接在旧 partial 后面。
    @Test(arguments: [true, false])
    func changedContentIdentityPreservesPartialAndRejectsFinalFile(usingETag: Bool) async throws {
        let fixture = Fixture()
        let original = fixture.addFile("a.bin", size: megabyte)
        let header = usingETag ? "ETag" : "Last-Modified"
        let oldValue = usingETag ? "\"version-1\"" : "Mon, 01 Jan 2024 00:00:00 GMT"
        let newValue = usingETag ? "\"version-2\"" : "Tue, 02 Jan 2024 00:00:00 GMT"
        fixture.server.setResponseHeaders([header: oldValue], for: "/a.bin")
        fixture.server.setStall(after: 64 * kilobyte)
        defer { fixture.server.setStall(after: nil) }
        let engine = fixture.makeEngine(.test(files: 1, connections: 1, retries: 0))
        let request = fixture.request("a.bin")
        try await engine.enqueue(request)
        try await waitUntil("original partial bytes") {
            await engine.snapshot(id: request.id)?.receivedBytes == Int64(64 * kilobyte)
        }
        await engine.pause(id: request.id)
        let before = try Data(contentsOf: request.temporaryURL)
        #expect(before == original.prefix(64 * kilobyte))
        fixture.server.setFile("/a.bin", Data(repeating: original[0] ^ 0xff, count: original.count))
        fixture.server.setResponseHeaders([header: newValue], for: "/a.bin")
        fixture.server.clearLog()
        fixture.server.setStall(after: nil)
        await engine.resume(id: request.id)
        try await waitUntil("changed identity to fail") {
            if case .failed = await engine.snapshot(id: request.id)?.state { return true }
            return false
        }
        #expect(await engine.snapshot(id: request.id)?.state == .failed(.invalidResponse("远端文件内容已变化，请重新添加任务")))
        #expect(fixture.server.log.count == 1)
        #expect(fixture.server.log.first?.headers["If-Range"] == oldValue)
        #expect(fixture.server.log.first?.range?.first == Int64(before.count))
        #expect(try Data(contentsOf: request.temporaryURL) == before)
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try fixture.savedRecords().first?.completedURL == nil)
        await engine.shutdown()
    }

    /// MD5 与预期不一致时保留数据供诊断，不产生可被当作成功的最终文件。
    @Test func mismatchedMD5DoesNotPublishCompletedFile() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var request = fixture.request("a.bin")
        request.expectedMD5 = (actual.first == "0" ? "1" : "0") + String(actual.dropFirst())
        let engine = fixture.makeEngine()
        try await engine.enqueue(request)
        try await waitUntil("MD5 verification to fail") {
            if case .failed = await engine.snapshot(id: request.id)?.state { return true }
            return false
        }
        #expect(await engine.snapshot(id: request.id)?.state == .failed(.invalidResponse("文件 MD5 与远端校验值不一致，请重新添加任务")))
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try Data(contentsOf: request.temporaryURL) == data)
        #expect(try fixture.savedRecords().first?.completedURL == nil)
        await engine.shutdown()
    }

    /// SHA-256 和 MD5 共用一次落盘读取；任一依据不符都不能发布正式文件。
    @Test(arguments: [true, false])
    func verifiesSHA256BeforePublishing(_ matches: Bool) async throws {
        let fixture = Fixture()
        let data = fixture.addFile("sha256.bin", size: megabyte)
        var request = fixture.request("sha256.bin")
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        request.expectedSHA256 = matches ? expected.uppercased() : (expected.first == "0" ? "1" : "0") + String(expected.dropFirst())
        request.expectedMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let engine = fixture.makeEngine()
        try await engine.enqueue(request)
        if matches {
            let destination = try await engine.waitForCompletion(of: request.id)
            #expect(try Data(contentsOf: destination) == data)
        } else {
            try await waitUntil("SHA-256 verification to fail") {
                if case .failed = await engine.snapshot(id: request.id)?.state { return true }
                return false
            }
            #expect(await engine.snapshot(id: request.id)?.state == .failed(.invalidResponse("文件 SHA-256 与预期校验值不一致，请重新添加任务")))
            #expect(!FileManager.default.fileExists(atPath: request.destination.path))
            #expect(try Data(contentsOf: request.temporaryURL) == data)
            #expect(try fixture.savedRecords().first?.completedURL == nil)
        }
        let snapshot = try #require(await engine.snapshot(id: request.id))
        #expect(snapshot.expectedSHA256 == request.expectedSHA256)
        #expect(snapshot.expectedMD5 == request.expectedMD5)
        await engine.shutdown()
    }

    /// 错误的校验值在发网络请求或写检查点之前拒绝。
    @Test func rejectsMalformedSHA256BeforeEnqueue() async throws {
        let fixture = Fixture()
        _ = fixture.addFile("invalid.bin", size: 4)
        var request = fixture.request("invalid.bin")
        request.expectedSHA256 = "not-a-sha256"
        let engine = fixture.makeEngine()
        do {
            try await engine.enqueue(request)
            Issue.record("Malformed SHA-256 was accepted")
        } catch {
            #expect(error as? DownloadFailure == .invalidResponse("下载内容校验值格式无效"))
        }
        #expect(fixture.server.log.isEmpty)
        #expect(try fixture.savedRecords().isEmpty)
        await engine.shutdown()
    }

    @Test(arguments: [
        URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed,
        .cannotConnectToHost, .cannotFindHost,
    ])
    func connectionErrorRefreshesLink(_ code: URLError.Code) async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { request, _ in request.token == "old" ? .fail(code) : nil }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 2)
        #expect(fixture.server.log.map(\.token) == ["old", "new"])
    }

    @Test func connectionLossKeepsLink() async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in index == 0 ? .fail(.networkConnectionLost) : nil }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 1)
        #expect(fixture.server.log.map(\.token) == ["old", "old"])
    }

    @Test func throttledResponsesBackOffLonger() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in index == 0 ? .status(429) : nil }
        let engine = fixture.makeEngine(.test(throttleMultiplier: 100))

        let start = ContinuousClock.now
        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(ContinuousClock.now - start >= .milliseconds(100))
        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 1)
    }

    @Test func failsAfterRetryLimitAndResumesFromCheckpoint() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        let failing = OSAllocatedUnfairLock(initialState: true)
        fixture.server.setFaultRule { request, _ in
            guard failing.withLock({ $0 }), let first = request.range?.first else { return nil }
            return first % Int64(256 * kilobyte) == 0
                ? .disconnect(afterBytes: 100 * kilobyte)
                : .status(500, body: #"{"error_code":2,"error_msg":"busy"}"#)
        }
        let engine = fixture.makeEngine(.test(connections: 2, retries: 2))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }

        let snapshot = try #require(await engine.snapshot(id: "a.bin"))
        guard case .failed(.httpStatus(500, let message)) = snapshot.state else {
            Issue.record("unexpected state \(snapshot.state)")
            return
        }
        #expect(message.contains("error_code"))
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.receivedBytes == snapshot.receivedBytes)
        #expect(saved.receivedBytes >= Int64(100 * kilobyte))

        failing.withLock { $0 = false }
        fixture.server.clearLog()
        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
    }

    /// 已有分片失去写权限时停止，不重试网络或发布最终文件；恢复权限后原位续传。
    @Test func readOnlyPartialFilePreservesCheckpointAndResumes() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("readonly.bin", size: megabyte)
        let request = fixture.request("readonly.bin")
        let engine = fixture.makeEngine(.test(connections: 1, retries: 3))
        fixture.server.setStall(after: 64 * kilobyte)
        try await engine.enqueue(request)
        try await waitUntil("initial writable prefix") {
            await engine.snapshot(id: request.id)?.receivedBytes == Int64(64 * kilobyte)
        }
        await engine.pause(id: request.id)
        let saved = try #require(fixture.savedRecords().first)
        let prefix = try Data(contentsOf: request.temporaryURL)
        #expect(prefix == data.prefix(64 * kilobyte))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: request.temporaryURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: request.temporaryURL.path) }
        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        await engine.resume(id: request.id)
        try await waitUntil("permission failure") {
            if case .failed(.fileSystem) = await engine.snapshot(id: request.id)?.state { true } else { false }
        }
        #expect(await engine.snapshot(id: request.id)?.receivedBytes == saved.receivedBytes)
        #expect(try Data(contentsOf: request.temporaryURL) == prefix)
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try fixture.savedRecords().first?.completedURL == nil)
        #expect(fixture.server.log.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: request.temporaryURL.path)
        await engine.resume(id: request.id)
        _ = try await engine.waitForCompletion(of: request.id)
        #expect(fixture.contents("readonly.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
        await engine.shutdown()
    }

    /// 文件内容完整但目标目录不能重命名时仍属于失败；恢复目录权限后直接发布原分片。
    @Test func unwritableDestinationPreservesCompletePartialUntilPublishCanRetry() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("publish.bin", size: megabyte)
        let request = fixture.request("publish.bin")
        let engine = fixture.makeEngine(.test(connections: 1, retries: 3))
        fixture.server.setStall(after: 64 * kilobyte)
        try await engine.enqueue(request)
        try await waitUntil("prefix before directory permission change") {
            await engine.snapshot(id: request.id)?.receivedBytes == Int64(64 * kilobyte)
        }
        await engine.pause(id: request.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.downloadsDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.downloadsDirectory.path) }
        fixture.server.setStall(after: nil)
        await engine.resume(id: request.id)
        try await waitUntil("final rename permission failure") {
            if case .failed(.fileSystem) = await engine.snapshot(id: request.id)?.state { true } else { false }
        }
        #expect(await engine.snapshot(id: request.id)?.receivedBytes == Int64(data.count))
        #expect(try Data(contentsOf: request.temporaryURL) == data)
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try fixture.savedRecords().first?.completedURL == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.downloadsDirectory.path)
        fixture.server.clearLog()
        await engine.resume(id: request.id)
        _ = try await engine.waitForCompletion(of: request.id)
        #expect(fixture.contents("publish.bin") == data)
        #expect(fixture.server.log.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        await engine.shutdown()
    }

    /// 仅显式挂载的独立小卷可填满；普通测试不依赖磁盘挂载，也不消耗用户数据卷的可用空间。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FERRY_TEST_DISK_FULL_VOLUME"] != nil,
                   "需要独立、已挂载且不超过32MiB的 FERRY_TEST_DISK_FULL_VOLUME，禁止指向用户数据卷"))
    func fullVolumePreservesPartialAndRestoresAfterSpaceIsFreed() async throws {
        let volumePath = try #require(ProcessInfo.processInfo.environment["FERRY_TEST_DISK_FULL_VOLUME"])
        let volume = URL(fileURLWithPath: volumePath, isDirectory: true).resolvingSymlinksInPath()
        let properties = try volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeURLKey])
        let capacity = try #require(properties.volumeTotalCapacity)
        try #require(capacity > 0 && capacity <= 32 * megabyte)
        try #require(properties.volume?.resolvingSymlinksInPath() == volume)
        let directory = volume.appendingPathComponent("FerryDiskFull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = Fixture()
        let data = fixture.addFile("full.bin", size: megabyte)
        var request = fixture.request("full.bin")
        request.destination = directory.appendingPathComponent("full.bin")
        let configuration = DownloadConfiguration.test(connections: 1, retries: 3)
        let engine = fixture.makeEngine(configuration)
        fixture.server.setStall(after: 64 * kilobyte)
        try await engine.enqueue(request)
        try await waitUntil("prefix before filling isolated volume") {
            await engine.snapshot(id: request.id)?.receivedBytes == Int64(64 * kilobyte)
        }
        await engine.pause(id: request.id)
        let saved = try #require(fixture.savedRecords().first)
        let prefix = try Data(contentsOf: request.temporaryURL)
        #expect(prefix == data.prefix(64 * kilobyte))
        let filler = directory.appendingPathComponent("bounded-filler.bin")
        try Data().write(to: filler)
        let handle = try FileHandle(forWritingTo: filler)
        var diskFull = false
        let chunk = Data(repeating: 0x7f, count: 512 * kilobyte)
        for _ in 0..<64 {
            do { try handle.write(contentsOf: chunk) }
            catch {
                let error = error as NSError
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                diskFull = error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) ||
                    underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOSPC) ||
                    error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue
                break
            }
        }
        try handle.close()
        try #require(diskFull, "独立小卷必须真实产生ENOSPC，而不是模拟网络错误")
        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        await engine.resume(id: request.id)
        try await waitUntil("real full-volume write failure") {
            if case .failed(.fileSystem) = await engine.snapshot(id: request.id)?.state { true } else { false }
        }
        #expect(await engine.snapshot(id: request.id)?.receivedBytes == saved.receivedBytes)
        #expect(try Data(contentsOf: request.temporaryURL) == prefix)
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        let failedRecord = try #require(fixture.savedRecords().first)
        #expect(failedRecord.completedURL == nil)
        #expect(failedRecord.receivedBytes == saved.receivedBytes)
        #expect(fixture.server.log.count == 1)
        // 移入本机废纸篓释放测试卷空间，保留样本；测试不删除用户文件。
        let trashedFiller = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/FerryPlus-ENOSPC-\(UUID().uuidString).bin")
        try FileManager.default.moveItem(at: filler, to: trashedFiller)
        await engine.shutdown()
        fixture.server.clearLog()
        let restored = fixture.makeEngine(configuration)
        _ = try await restored.restore()
        #expect(await restored.snapshot(id: request.id)?.receivedBytes == saved.receivedBytes)
        await restored.resume(id: request.id)
        _ = try await restored.waitForCompletion(of: request.id)
        #expect(try Data(contentsOf: request.destination) == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        await restored.shutdown()
    }

    @Test func pauseAndResume() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("4 × 128 KB received") {
            await engine.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        await engine.pause(id: "a.bin")

        #expect(await engine.snapshot(id: "a.bin")?.state == .paused)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.isPaused)
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        try await waitUntil("requests to stop") { fixture.server.activeRequests == 0 }

        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
    }

    @Test func restoreInNewEngineContinuesFromSavedProgress() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        let other = fixture.addFile("b.bin", size: 300 * kilobyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let first = fixture.makeEngine(.test(files: 1))

        try await first.enqueue(fixture.request("a.bin"))
        try await first.enqueue(fixture.request("b.bin"))
        await first.pause(id: "b.bin")
        try await waitUntil("4 × 128 KB received") {
            await first.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        await first.shutdown()
        let stateStore = StateStore(directory: fixture.stateDirectory)
        let originalA = try Data(contentsOf: stateStore.fileURL(for: "a.bin"))
        let originalB = try Data(contentsOf: stateStore.fileURL(for: "b.bin"))

        let saved = try #require(try fixture.savedRecords().first { $0.request.id == "a.bin" })
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        #expect(!saved.isPaused)

        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        let second = fixture.makeEngine(.test(files: 1))
        let restored = try await second.restore()
        #expect(try Data(contentsOf: stateStore.fileURL(for: "a.bin").appendingPathExtension("before-v3")) == originalA)
        #expect(try Data(contentsOf: stateStore.fileURL(for: "b.bin").appendingPathExtension("before-v3")) == originalB)

        #expect(restored.map(\.id) == ["a.bin", "b.bin"])
        #expect(restored.map(\.state) == [.queued, .paused])
        #expect(restored.first?.receivedBytes == Int64(512 * kilobyte))
        _ = try await second.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
        #expect(try Data(contentsOf: stateStore.fileURL(for: "a.bin")) != originalA)
        _ = try await second.restore()
        #expect(try Data(contentsOf: stateStore.fileURL(for: "a.bin").appendingPathExtension("before-v3")) == originalA)
        #expect(try Data(contentsOf: stateStore.fileURL(for: "b.bin").appendingPathExtension("before-v3")) == originalB)

        await second.resume(id: "b.bin")
        _ = try await second.waitForCompletion(of: "b.bin")
        #expect(fixture.contents("b.bin") == other)
    }

    @Test func runtimeSuspensionPreservesPauseAndResumesCheckpointOnReplacementSession() async throws {
        let fixture = Fixture()
        let expected = fixture.addFile("runtime.bin", size: megabyte)
        fixture.addFile("manual.bin", size: megabyte)
        let queuedData = fixture.addFile("queued.bin", size: 32 * kilobyte)
        fixture.addFile("after-shutdown.bin", size: kilobyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine(.test(files: 1, connections: 1))
        try await engine.enqueue(fixture.request("runtime.bin"))
        try await engine.enqueue(fixture.request("manual.bin"))
        await engine.pause(id: "manual.bin")
        try await waitUntil("runtime checkpoint bytes") { await engine.snapshot(id: "runtime.bin")?.receivedBytes == Int64(128 * kilobyte) }
        await engine.suspendExecution()
        // URLSession 已交付取消完成时，StubServer 的独立线程可能仍在退出 1 ms 停顿循环。
        // 等它实际归零后再继续，超时仍报错；不把服务器线程调度当成引擎同步返回合同。
        try await waitUntil("suspended server request to finish") { fixture.server.activeRequests == 0 }
        #expect(await engine.snapshot(id: "runtime.bin")?.state == .queued)
        #expect(await engine.snapshot(id: "manual.bin")?.state == .paused)
        let saved = try #require(try fixture.savedRecords().first { $0.request.id == "runtime.bin" })
        #expect(!saved.isPaused && saved.receivedBytes == Int64(128 * kilobyte))
        #expect(try fixture.savedRecords().first { $0.request.id == "manual.bin" }?.isPaused == true)
        fixture.server.clearLog()
        try await engine.enqueue(fixture.request("queued.bin"))
        await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "runtime-new"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.server.log.isEmpty)
        fixture.server.setStallRule { _ in nil }
        await engine.resumeExecution()
        _ = try await engine.waitForCompletion(of: "runtime.bin")
        _ = try await engine.waitForCompletion(of: "queued.bin")
        #expect(fixture.contents("runtime.bin") == expected)
        #expect(fixture.contents("queued.bin") == queuedData)
        #expect(await engine.snapshot(id: "manual.bin")?.state == .paused)
        #expect(fixture.server.log.allSatisfy { $0.headers["X-Session"] == "runtime-new" })
        expectOnlyMissingBytesRequested(fixture.server.log.filter { $0.url.path == "/runtime.bin" }, after: saved)
        await engine.shutdown()
        fixture.server.clearLog()
        try await engine.enqueue(fixture.request("after-shutdown.bin"))
        await engine.resumeExecution()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.server.log.isEmpty)
    }

    @Test func runtimeResumeDuringDrainWaitsForPreviousWorker() async throws {
        let fixture = Fixture()
        fixture.addFile("runtime-a.bin", size: kilobyte)
        fixture.addFile("runtime-b.bin", size: kilobyte)
        let source = GatedSource(fixture.source, gating: ["runtime-a.bin", "runtime-b.bin"])
        defer { source.open() }
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(files: 1), session: fixture.session)
        try await engine.enqueue(fixture.request("runtime-a.bin"))
        try await waitUntil("first runtime worker started") { source.hasEntered("runtime-a.bin") }
        let suspended = Task { await engine.suspendExecution() }
        try await waitUntil("runtime suspension cancelled worker") { source.wasCancelled("runtime-a.bin") }
        await engine.resumeExecution()
        try await engine.enqueue(fixture.request("runtime-b.bin"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!source.hasEntered("runtime-b.bin"))
        #expect(fixture.server.log.isEmpty)
        source.open()
        await suspended.value
        _ = try await engine.waitForCompletion(of: "runtime-a.bin")
        _ = try await engine.waitForCompletion(of: "runtime-b.bin")
        await engine.shutdown()
    }

    @Test func runtimeSuspensionBlocksSessionReplacementRestart() async throws {
        let fixture = Fixture()
        fixture.addFile("runtime.bin", size: kilobyte)
        let source = GatedSource(fixture.source, gating: ["runtime.bin"])
        defer { source.open() }
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)
        try await engine.enqueue(fixture.request("runtime.bin"))
        try await waitUntil("runtime source entered") { source.hasEntered("runtime.bin") }
        let suspended = Task { await engine.suspendExecution() }
        try await waitUntil("runtime cancellation") { source.wasCancelled("runtime.bin") }
        let replaced = Task { await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "runtime-new")) }
        source.open()
        await suspended.value
        await replaced.value
        #expect(await engine.snapshot(id: "runtime.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)
        #expect(try fixture.savedRecords().allSatisfy { !$0.isPaused })
        await engine.resumeExecution()
        _ = try await engine.waitForCompletion(of: "runtime.bin")
        #expect(fixture.server.log.allSatisfy { $0.headers["X-Session"] == "runtime-new" })
        await engine.shutdown()
    }

    @Test func runtimeSuspensionAwaitsRemovedCancellingWorker() async throws {
        let fixture = Fixture()
        fixture.addFile("runtime.bin", size: kilobyte)
        let source = GatedSource(fixture.source, gating: ["runtime.bin"])
        defer { source.open() }
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)
        try await engine.enqueue(fixture.request("runtime.bin"))
        try await waitUntil("runtime source entered") { source.hasEntered("runtime.bin") }
        let cancelled = Task { await engine.cancel(id: "runtime.bin") }
        try await waitUntil("runtime cancellation removed entry") { await engine.snapshot(id: "runtime.bin") == nil }
        let finished = OSAllocatedUnfairLock(initialState: false)
        let suspended = Task { await engine.suspendExecution(); finished.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished.withLock { $0 })
        source.open()
        await suspended.value
        await cancelled.value
        #expect(finished.withLock { $0 })
        #expect(fixture.server.log.isEmpty)
        #expect(try fixture.savedRecords().isEmpty)
        await engine.shutdown()
    }

    @Test func replacingSessionContinuesFromCheckpointOnNewSession() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        // 旧会话的请求停在 128 KB。新会话的请求先停在开头，取得换会话时保存的进度后再放行。
        let released = OSAllocatedUnfairLock(initialState: false)
        fixture.server.setStallRule { request in
            guard request.headers["X-Session"] == "new" else { return 128 * kilobyte }
            return released.withLock { $0 } ? nil : 0
        }
        let engine = fixture.makeEngine()
        let events = engine.events()
        let collector = Task {
            var states: [DownloadState] = []
            for await case .stateChanged(let snapshot) in events {
                states.append(snapshot.state)
                if case .completed = snapshot.state { break }
            }
            return states
        }

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("4 × 128 KB received") {
            await engine.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        let oldRequests = fixture.server.log.count
        await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))

        #expect(await engine.snapshot(id: "a.bin")?.state == .running)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        released.withLock { $0 = true }
        let location = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        #expect(log.prefix(oldRequests).allSatisfy { $0.headers["X-Session"] == nil })
        let newRequests = Array(log.dropFirst(oldRequests))
        #expect(!newRequests.isEmpty)
        #expect(newRequests.allSatisfy { $0.headers["X-Session"] == "new" })
        expectOnlyMissingBytesRequested(newRequests, after: saved)

        let states = await collector.value
        #expect(states.first == .queued)
        #expect(states.dropFirst().dropLast().allSatisfy { $0 == .running })
        #expect(states.last == .completed(location))
    }

    @Test func replacingSessionAfterShutdownStartsNothing() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("1 active request") { fixture.server.activeRequests == 1 }
        await engine.shutdown()
        fixture.server.clearLog()
        await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))

        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.snapshot(id: "a.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)
    }

    @Test func shutdownDuringSessionReplacementStartsNothing() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.addFile("b.bin", size: megabyte)
        let source = GatedSource(fixture.source, gating: ["a.bin", "b.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin to wait for its link") { source.hasEntered("a.bin") }
        let replaced = Task { await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new")) }
        try await waitUntil("replaceSession to cancel a.bin") { source.wasCancelled("a.bin") }
        // b.bin 在新会话上开始。它被取消，说明 shutdown 已经开始。
        try await engine.enqueue(fixture.request("b.bin"))
        try await waitUntil("b.bin to wait for its link") { source.hasEntered("b.bin") }
        let shutDown = Task { await engine.shutdown() }
        try await waitUntil("shutdown to cancel b.bin") { source.wasCancelled("b.bin") }
        source.open()
        await replaced.value
        await shutDown.value

        #expect(await engine.snapshot(id: "a.bin")?.state == .queued)
        #expect(await engine.snapshot(id: "b.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)
        #expect(try fixture.savedRecords().allSatisfy { !$0.isPaused })
    }

    @Test func pauseDuringSessionReplacementStaysPaused() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin to wait for its link") { source.hasEntered("a.bin") }
        let replaced = Task { await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new")) }
        try await waitUntil("replaceSession to cancel a.bin") { source.wasCancelled("a.bin") }
        let paused = Task { await engine.pause(id: "a.bin") }
        try await waitUntil("a.bin to be paused") { await engine.snapshot(id: "a.bin")?.state == .paused }
        source.open()
        await replaced.value
        await paused.value

        #expect(await engine.snapshot(id: "a.bin")?.state == .paused)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.isPaused)
        #expect(fixture.server.log.isEmpty)

        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.server.log.allSatisfy { $0.headers["X-Session"] == "new" })
    }

    @Test func cancelDuringSessionReplacementEndsBeforeReplacementReturns() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        let data = fixture.addFile("b.bin", size: megabyte)
        fixture.server.setStallRule { $0.headers["X-Session"] == nil ? 128 * kilobyte : nil }
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await engine.enqueue(fixture.request("b.bin"))
        try await waitUntil("a.bin to wait for its link and b.bin to stall") {
            source.hasEntered("a.bin") && fixture.server.activeRequests == 4
        }
        // cancel(id:) 已经把 a.bin 移出队列，还在等它的传输任务结束。
        let cancelled = Task { await engine.cancel(id: "a.bin") }
        try await waitUntil("a.bin to be removed") { await engine.snapshot(id: "a.bin") == nil }
        let replaced = Task {
            await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))
            return source.isOpen
        }
        // b.bin 已经在新会话上重新开始，换会话只剩 a.bin 的传输任务要等。
        try await waitUntil("b.bin to restart on the new session") {
            fixture.server.log.contains { $0.headers["X-Session"] == "new" }
        }
        source.open()

        #expect(await replaced.value, "replaceSession returned before the transfer of a.bin ended")
        await cancelled.value
        _ = try await engine.waitForCompletion(of: "b.bin")
        #expect(fixture.contents("b.bin") == data)
        #expect(!fixture.server.log.contains { $0.url.path == "/a.bin" })
        #expect(try fixture.savedRecords().map(\.request.id) == ["b.bin"])
        #expect(!FileManager.default.fileExists(atPath: fixture.request("a.bin").temporaryURL.path))
    }

    /// 移出列表的取消任务要等链接源收尾；期间新任务仍应排队，不能突破全局文件数。
    @Test func cancellingWorkerKeepsItsGlobalConcurrencySlotUntilFinished() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: 100 * kilobyte)
        let expected = fixture.addFile("b.bin", size: 100 * kilobyte)
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        defer { source.open() }
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: .test(files: 1), session: fixture.session)
        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin waits for its link") { source.hasEntered("a.bin") }

        let cancellation = Task { await engine.cancel(id: "a.bin") }
        try await waitUntil("a.bin cancellation reaches the source") { source.wasCancelled("a.bin") }
        try await engine.enqueue(fixture.request("b.bin"))
        #expect(await engine.snapshot(id: "a.bin") == nil)
        #expect(await engine.snapshot(id: "b.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)

        source.open()
        await cancellation.value
        _ = try await engine.waitForCompletion(of: "b.bin")
        #expect(fixture.contents("b.bin") == expected)
        await engine.shutdown()
    }

    /// 同 ID 的清理与重新加入不能交叠，避免旧取消删除新下载的分片和状态文件。
    @Test func sameIDIsReservedUntilCancellationCleanupCompletes() async throws {
        let fixture = Fixture()
        let expected = fixture.addFile("a.bin", size: 100 * kilobyte)
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        defer { source.open() }
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: .test(files: 1), session: fixture.session)
        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin waits for its first link") { source.hasEntered("a.bin") }

        let cancellation = Task { await engine.cancel(id: "a.bin") }
        try await waitUntil("a.bin cancellation reaches the source") { source.wasCancelled("a.bin") }
        try await engine.enqueue(fixture.request("a.bin"))
        #expect(await engine.snapshot(id: "a.bin") == nil)
        #expect(try await engine.restore().isEmpty)
        #expect(await engine.snapshot(id: "a.bin") == nil)
        #expect(fixture.server.log.isEmpty)

        source.open()
        await cancellation.value
        #expect(try fixture.savedRecords().isEmpty)
        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == expected)
        let record = try #require(try fixture.savedRecords().first)
        #expect(record.request.id == "a.bin")
        #expect(record.receivedBytes == Int64(expected.count))
        #expect(record.completedURL != nil)
        await engine.shutdown()
    }

    @Test func savesProgressPeriodicallyAndCancelRemovesFiles() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))
        let events = engine.events()

        let request = fixture.request("a.bin")
        try await engine.enqueue(request)
        try await waitUntil("checkpoint with 128 KB") {
            try fixture.savedRecords().first?.receivedBytes == Int64(128 * kilobyte)
        }
        #expect(FileManager.default.fileExists(atPath: request.temporaryURL.path))

        #expect(await engine.cancel(id: "a.bin") == nil)

        #expect(await engine.snapshot(id: "a.bin") == nil)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try fixture.savedRecords().isEmpty)
        for await event in events {
            if event == .removed(id: "a.bin") { break }
        }
    }

    @Test func completedRecordIsKeptUntilCancel() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 300 * kilobyte)
        let first = fixture.makeEngine()
        try await first.enqueue(fixture.request("a.bin"))
        let location = try await first.waitForCompletion(of: "a.bin")
        await first.shutdown()
        #expect(try fixture.savedRecords().map(\.completedURL) == [location])

        // 应用在保存最终路径前退出：新的引擎把它恢复为 completed，不再下载。
        fixture.server.clearLog()
        let second = fixture.makeEngine()
        let restored = try await second.restore()
        #expect(restored.map(\.state) == [.completed(location)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await second.snapshot(id: "a.bin")?.state == .completed(location))
        #expect(fixture.server.log.isEmpty)
        #expect(fixture.source.resolveCount == 1)

        #expect(await second.cancel(id: "a.bin") == location)
        #expect(await second.snapshot(id: "a.bin") == nil)
        #expect(try fixture.savedRecords().isEmpty)
        #expect(fixture.contents("a.bin") == data)
        #expect(try await fixture.makeEngine().restore().isEmpty)
    }

    @Test func doesNotOverwriteExistingFiles() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 300 * kilobyte)
        let existing = Data("old".utf8)
        try FileManager.default.createDirectory(at: fixture.downloadsDirectory, withIntermediateDirectories: true)
        try existing.write(to: fixture.downloadsDirectory.appendingPathComponent("a.bin"))
        try existing.write(to: fixture.downloadsDirectory.appendingPathComponent("a (1).bin"))
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        let location = try await engine.waitForCompletion(of: "a.bin")

        #expect(location.lastPathComponent == "a (2).bin")
        #expect(fixture.contents("a (2).bin") == data)
        #expect(fixture.contents("a.bin") == existing)
        #expect(fixture.contents("a (1).bin") == existing)
    }

    @Test func sameDestinationUsesSeparateTemporaryFiles() async throws {
        let fixture = Fixture()
        let first = fixture.addFile("one.bin", size: megabyte)
        let second = fixture.addFile("two.bin", size: megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(files: 2, connections: 2))
        let destination = fixture.downloadsDirectory.appendingPathComponent("same.bin")
        var one = fixture.request("one.bin")
        one.destination = destination
        var two = fixture.request("two.bin")
        two.destination = destination
        #expect(one.temporaryURL != two.temporaryURL)
        #expect(one.temporaryURL.deletingLastPathComponent().path == fixture.downloadsDirectory.path)

        try await engine.enqueue(one)
        try await engine.enqueue(two)
        try await waitUntil("both files downloading") { fixture.server.activeRequests == 4 }
        fixture.server.setStall(after: nil)
        let locations = [
            try await engine.waitForCompletion(of: "one.bin"),
            try await engine.waitForCompletion(of: "two.bin"),
        ]

        #expect(Set(locations.map(\.lastPathComponent)) == ["same.bin", "same (1).bin"])
        #expect(try Data(contentsOf: locations[0]) == first)
        #expect(try Data(contentsOf: locations[1]) == second)
    }

    /// 已存在的字节不能因 Range 能力改变或恢复不可续传下载而静默截断。
    @Test(arguments: [true, false])
    func unsupportedResumePreservesCheckpointAndRequestsNewDownload(previouslySupportedRanges: Bool) async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setSupportsRanges(false)
        let request = fixture.request("a.bin")
        let prefix = Data(data.prefix(128 * kilobyte))
        try FileManager.default.createDirectory(at: fixture.downloadsDirectory, withIntermediateDirectories: true)
        try prefix.write(to: request.temporaryURL)
        var record = DownloadRecord(request: request)
        record.acceptsRanges = previouslySupportedRanges
        record.segments = [Segment(start: 0, end: Int64(data.count), received: Int64(prefix.count))]
        try StateStore(directory: fixture.stateDirectory).save(record)
        let engine = fixture.makeEngine()

        try await engine.restore()
        try await waitUntil("unsupported resume to fail") {
            if case .failed = await engine.snapshot(id: request.id)?.state { true } else { false }
        }
        let snapshot = try #require(await engine.snapshot(id: request.id))
        guard case .failed(.invalidResponse(let message)) = snapshot.state else {
            Issue.record("unexpected state \(snapshot.state)")
            return
        }
        #expect(message.contains("不支持断点续传"))
        #expect(message.contains("重新添加"))
        #expect(snapshot.receivedBytes == Int64(prefix.count))
        #expect(try Data(contentsOf: request.temporaryURL) == prefix)
        #expect(try fixture.savedRecords().first?.receivedBytes == Int64(prefix.count))
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(fixture.server.log.allSatisfy { $0.range != nil })
        if !previouslySupportedRanges { #expect(fixture.server.log.isEmpty) }
        await engine.shutdown()
    }

    @Test(arguments: [true, false])
    func fallsBackToSingleConnectionWithoutRangeSupport(knownSize: Bool) async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setSupportsRanges(false)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin", knownSize: knownSize))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        #expect(log.last?.headers["Range"] == nil)
        #expect(log.count { $0.headers["Range"] == nil } == 1)
        if !knownSize {
            #expect(log.count == 2)
        }
    }

    @Test func rejectsMalformedResponses() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setFaultRule { _, index in
            switch index {
            case 0: .wrongContentRange
            case 1: .shortBody
            case 2: .okWithBody("<html>error</html>")
            default: nil
            }
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.server.log.allSatisfy { $0.range != nil })
    }

    @Test func reportsServerErrorMessage() async throws {
        let fixture = Fixture(tokens: ["old"])
        fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.expire(token: "old")
        let engine = fixture.makeEngine(.test(retries: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }

        let state = await engine.snapshot(id: "a.bin")?.state
        #expect(state == .failed(.httpStatus(403, message: #"{"error_code":31326,"error_msg":"link expired"}"#)))
        #expect(fixture.source.resolveCount == 2)
    }

    @Test func permanentResolveErrorFailsWithoutRetry() async throws {
        let (state, resolveCount) = try await resolveFailure(PermanentError(), retries: 3)
        #expect(state == .failed(.resolveFailed("登录已失效。")))
        #expect(resolveCount == 1)
    }

    @Test func resolveErrorsAreRetriedAndReportTheirDescription() async throws {
        let (state, resolveCount) = try await resolveFailure(TransientError(), retries: 2)
        #expect(state == .failed(.resolveFailed("暂时取不到链接。")))
        #expect(resolveCount == 3)

        let plain = PlainError()
        let (plainState, _) = try await resolveFailure(plain, retries: 0)
        #expect(plainState == .failed(.resolveFailed(plain.localizedDescription)))
    }

    /// 用总是失败的下载源下载一个文件，返回最终状态和调用下载源的次数。
    private func resolveFailure(_ error: any Error & Sendable, retries: Int) async throws -> (DownloadState?, Int) {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: 100 * kilobyte)
        let source = ThrowingSource(error)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: .test(retries: retries), session: fixture.session)
        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }
        #expect(fixture.server.log.isEmpty)
        return (await engine.snapshot(id: "a.bin")?.state, source.resolveCount)
    }

    @Test func emptyFileCompletesWithoutRequests() async throws {
        let fixture = Fixture()
        fixture.addFile("empty.txt", size: 0)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("empty.txt"))
        _ = try await engine.waitForCompletion(of: "empty.txt")

        #expect(fixture.contents("empty.txt") == Data())
        #expect(fixture.server.log.isEmpty)
        #expect(fixture.source.resolveCount == 0)
    }

    @Test func crossHostRedirectKeepsHeadersExceptCookie() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        let cdnHost = "cdn-\(fixture.server.host)"
        fixture.server.addAlias(cdnHost)
        fixture.server.setFaultRule { _, index in
            index == 0 ? .redirect(to: URL(string: "https://\(cdnHost)/a.bin")!) : nil
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let redirected = try #require(fixture.server.log.last)
        #expect(redirected.url.host() == cdnHost)
        #expect(redirected.headers["Cookie"] == nil)
        #expect(redirected.headers["User-Agent"] == "FerryTests")
        #expect(redirected.headers["Range"] == "bytes=0-\(data.count - 1)")
    }

    @Test func sameHostRedirectKeepsCookie() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in
            index == 0 ? .redirect(to: fixture.server.url("/a.bin?moved=1")) : nil
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let redirected = try #require(fixture.server.log.last)
        #expect(redirected.url.query() == "moved=1")
        #expect(redirected.headers["Cookie"] == "BDUSS=test")
        #expect(redirected.headers["Range"] == "bytes=0-\(data.count - 1)")
    }
}

private struct PermanentError: PermanentDownloadSourceError, LocalizedError {
    var errorDescription: String? { "登录已失效。" }
}

private struct TransientError: LocalizedError {
    var errorDescription: String? { "暂时取不到链接。" }
}

private struct PlainError: Error {}

/// 每次都抛出同一个错误的下载源。
private final class ThrowingSource: DownloadSource {
    private let error: any Error & Sendable
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(_ error: any Error & Sendable) {
        self.error = error
    }

    var resolveCount: Int { count.withLock { $0 } }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        count.withLock { $0 += 1 }
        throw error
    }
}

/// 指定的文件下载取链接时停住，直到 `open()`。停住时不响应取消，所以传输任务被取消后要等 `open()` 才结束。
private final class GatedSource: DownloadSource {
    private struct State {
        var isOpen = false
        var entered: Set<String> = []
        var cancelled: Set<String> = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let base: StubSource
    private let gated: Set<String>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ base: StubSource, gating gated: Set<String>) {
        self.base = base
        self.gated = gated
    }

    var isOpen: Bool { state.withLock { $0.isOpen } }
    func hasEntered(_ id: String) -> Bool { state.withLock { $0.entered.contains(id) } }
    func wasCancelled(_ id: String) -> Bool { state.withLock { $0.cancelled.contains(id) } }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let id = request.id
        if gated.contains(id) {
            state.withLock { _ = $0.entered.insert(id) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let isOpen = state.withLock { state in
                        if !state.isOpen { state.waiters.append(continuation) }
                        return state.isOpen
                    }
                    if isOpen { continuation.resume() }
                }
            } onCancel: {
                state.withLock { _ = $0.cancelled.insert(id) }
            }
        }
        return try await base.resolve(request)
    }
}

/// 续传后的请求只覆盖保存时还缺的字节，每个字节只请求一次。
private func expectOnlyMissingBytesRequested(
    _ log: [LoggedRequest],
    after saved: DownloadRecord,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let received = (saved.segments ?? []).map { $0.start..<$0.offset }
    var requested: Int64 = 0
    for request in log {
        guard let range = request.range, let last = range.last else {
            Issue.record("request without a bounded range", sourceLocation: sourceLocation)
            continue
        }
        requested += last - range.first + 1
        let bytes = range.first..<(last + 1)
        #expect(!received.contains { $0.overlaps(bytes) }, sourceLocation: sourceLocation)
    }
    #expect(requested == saved.totalBytes! - saved.receivedBytes, sourceLocation: sourceLocation)
}
