import BaiduKit
@testable import DownloadKit
import Foundation
import Testing
import QuarkKit
import os
@testable import FerryCore

@MainActor @Suite struct JobCoordinatorTests {
    /// 当前分网盘连接数覆盖恢复记录，并在共享最大值不变时分别更新两家暂停任务。
    @Test func settingsUpdateExistingRequestsForBothProvidersAndKeepPause() async throws {
        let fixture = Fixture()
        var jobs: [Job] = []
        let stateStore = StateStore(directory: fixture.stateDirectory)
        for provider in Provider.allCases {
            let reference: RemoteReference = provider == .baidu ? .baidu(path: "/baidu.bin", fsID: 1) : .quark(fid: "quark-file")
            let entry = RemoteEntry(reference: reference, name: "\(provider.rawValue).bin", isDirectory: false, size: 1024)
            let account = AccountKey(provider: provider, accountID: "1")
            var file = JobFile(remotePath: reference.identifier, relativePath: entry.name, size: entry.size)
            file.remoteReference = reference
            var job = Job(netdiskEntries: [entry])
            job.accountKey = account
            job.files = [file]
            job.phase = .downloading
            job.isPaused = true
            jobs.append(job)
            let request = DownloadRequest(id: file.id, destination: fixture.downloads.appendingPathComponent(entry.name),
                                          expectedSize: entry.size,
                                          context: try DownloadContext(account: account, reference: reference, size: entry.size).encoded(),
                                          connections: 6)
            var record = DownloadRecord(request: request)
            record.isPaused = true
            try stateStore.save(record)
        }
        try fixture.store.save(jobs)
        var settings = FerrySettings(cleanupAfterDownload: false, maxConcurrentFiles: 2, connectionsPerFile: 3)
        settings.quarkConnectionsPerFile = 3
        let coordinator = fixture.makeCoordinator(settings: settings)
        await coordinator.start()
        #expect(try stateStore.loadAll().allSatisfy { $0.request.connections == 3 && $0.isPaused })
        for (baidu, quark) in [(1, 3), (3, 1)] {
            settings.connectionsPerFile = baidu
            settings.quarkConnectionsPerFile = quark
            await coordinator.updateSettings(settings)
            let records = try stateStore.loadAll()
            for job in jobs {
                let record = try #require(records.first { $0.request.id == job.files[0].id })
                #expect(record.request.connections == settings.connections(for: job.provider))
                #expect(record.isPaused)
                #expect(coordinator.job(job.id)?.isPaused == true)
            }
        }
        await coordinator.shutdown()
    }

    /// 正式客户端读取账号及分享目录时，必须继续取第二页并保留请求的目录和会话参数。
    @Test(arguments: [false, true])
    func quarkClientListsAllPagesOfAccountAndShareDirectories(_ share: Bool) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let path = share ? "/1/clouddrive/share/sharepage/detail" : "/1/clouddrive/file/sort"
        let first = try quarkListResponse(ids: (0..<100).map { "file-\($0)" }, total: 101)
        let second = try quarkListResponse(ids: ["file-100"], total: 101)
        stub.state.withLock {
            $0.listingResponses[path] = [1: first, 2: second]
        }
        let client = stub.makeClient()
        defer { client.revoke() }
        let entries = try await quarkList(client, share: share)
        #expect(entries.map(\.fid) == (0..<101).map { "file-\($0)" })
        let requests = stub.state.withLock { $0.listingRequests }
        #expect(requests.map(\.path) == [path, path])
        #expect(requests.map { $0.query["_page"] } == ["1", "2"])
        #expect(requests.allSatisfy { $0.query["_size"] == "100" && $0.query["_fetch_total"] == "1" && $0.query["pdir_fid"] == "selected" })
        if share {
            #expect(requests.allSatisfy { $0.query["pwd_id"] == "test123" && $0.query["stoken"] == "test-only" })
        }
    }

    /// 后续页业务失败必须抛出原错误，不能把首页的 100 项当作完整目录返回。
    @Test(arguments: [false, true], ["401", "500"])
    func quarkClientRejectsPartialListingWhenSecondPageFails(_ share: Bool, _ code: String) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let path = share ? "/1/clouddrive/share/sharepage/detail" : "/1/clouddrive/file/sort"
        let first = try quarkListResponse(ids: (0..<100).map { "file-\($0)" }, total: 101)
        stub.state.withLock {
            $0.listingResponses[path] = [1: first, 2: "{\"status\":400,\"code\":\"\(code)\"}"]
        }
        let client = stub.makeClient()
        defer { client.revoke() }
        do {
            _ = try await quarkList(client, share: share)
            Issue.record("A failed second page must not return the first page as a complete directory.")
        } catch let error as QuarkError {
            #expect(error == (code == "401" ? .loginExpired : .serviceCode(code)))
        }
        #expect(stub.state.withLock { $0.listingRequests.map { $0.query["_page"] } } == ["1", "2"])
    }

    /// 分页总数自相矛盾、提前空页或跨页重复 ID 都不能产生可供下载的完整列表。
    @Test(arguments: [false, true], ["duplicate", "total-underflow", "empty-before-total", "total-overflow"])
    func quarkClientRejectsInconsistentPagination(_ share: Bool, _ failure: String) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let path = share ? "/1/clouddrive/share/sharepage/detail" : "/1/clouddrive/file/sort"
        let first = try quarkListResponse(ids: (0..<100).map { "file-\($0)" }, total: failure == "total-underflow" ? 99 : 101)
        let secondIDs: [String]
        switch failure {
        case "duplicate": secondIDs = ["file-0"]
        case "empty-before-total": secondIDs = []
        default: secondIDs = ["file-100", "file-101"]
        }
        let second = try quarkListResponse(ids: secondIDs, total: 101)
        stub.state.withLock { $0.listingResponses[path] = [1: first, 2: second] }
        let client = stub.makeClient()
        defer { client.revoke() }
        do {
            _ = try await quarkList(client, share: share)
            Issue.record("Invalid pagination must not return a complete directory.")
        } catch let error as QuarkError {
            #expect(error == .invalidResponse)
        }
        #expect(stub.state.withLock { $0.listingRequests.count } == (failure == "total-underflow" ? 1 : 2))
    }

    private func quarkList(_ client: QuarkClient, share: Bool) async throws -> [QuarkEntry] {
        if share {
            let link = try QuarkShareLink.parse("https://pan.quark.cn/s/test123")
            let session = try await client.openShare(link)
            return try await client.listShareDirectory(session: session, parentFID: "selected")
        }
        return try await client.listDirectory(parentFID: "selected")
    }

    private func quarkListResponse(ids: [String], total: Int) throws -> String {
        let list = ids.map { ["fid": $0, "file_name": "\($0).bin", "dir": false, "size": 1, "pdir_fid": "selected"] as [String: Any] }
        let response: [String: Any] = ["status": 200, "code": 0, "data": ["list": list], "metadata": ["_total": total]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    @Test(arguments: [401, 403, 404, 429])
    func quarkAPIHTTPFailuresKeepMeaningAndUseBoundedResolveRetries(_ status: Int) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock { $0.httpStatus = status }
        let client = stub.makeClient()
        let expected: QuarkError = status == 401 ? .loginExpired : .httpStatus(status)
        do {
            _ = try await client.download(fid: "file")
            Issue.record("HTTP failure must not produce a download URL.")
        } catch let error as QuarkError { #expect(error == expected) }
        #expect(stub.state.withLock { $0.downloadRequests } == 1)
        stub.state.withLock { $0.downloadRequests = 0 }
        try await expectQuarkResolveFailure(stub: stub, client: client, expected: expected,
                                           requestCount: status == 429 ? 3 : 1)
        let description = try #require(expected.errorDescription)
        if status == 403 {
            #expect(description.contains("访问权限"))
            #expect(!description.contains("登录已失效"))
        } else if status == 404 { #expect(description.contains("确认文件或分享")) }
        else if status == 429 { #expect(description.contains("降低并发数")) }
    }

    @Test(arguments: [false, true])
    func quarkCapacityResolveFailureDoesNotRetryWithOrWithoutMessage(_ hasMessage: Bool) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock {
            $0.downloadBusinessCode = "32003"
            $0.downloadFailureMessage = hasMessage ? "capacity limit[{0}]" : nil
        }
        let expected: QuarkError = hasMessage ? .serviceFailure(code: "32003", message: "capacity limit[{0}]") : .serviceCode("32003")
        try await expectQuarkResolveFailure(stub: stub, client: stub.makeClient(), expected: expected, requestCount: 1)
    }

    /// 通过真实路由和引擎检查 API 错误的重试次数，不触发任何 CDN 下载。
    private func expectQuarkResolveFailure(stub: QuarkAPIStub, client: QuarkClient,
                                          expected: QuarkError, requestCount: Int) async throws {
        let fixture = Fixture()
        let source = RoutedDownloadSource()
        let account = AccountKey(provider: .quark, accountID: "test")
        source.setQuark(client, account: account)
        let engine = DownloadEngine(stateDirectory: fixture.directory.appendingPathComponent("state"), source: source,
                                    configuration: DownloadConfiguration(maxRetries: 2, retryBaseDelay: .milliseconds(1), retryMaxDelay: .milliseconds(1)))
        let request = DownloadRequest(id: "quark-failure", destination: fixture.directory.appendingPathComponent("file"),
                                      expectedSize: 12,
                                      context: try DownloadContext(account: account, reference: .quark(fid: "file"), size: 12).encoded())
        try await engine.enqueue(request)
        try await waitUntil("Quark resolve failure") {
            if case .failed = await engine.snapshot(id: request.id)?.state { true } else { false }
        }
        let snapshot = await engine.snapshot(id: request.id)
        #expect(snapshot?.state == .failed(.resolveFailed(expected.localizedDescription)))
        #expect(stub.state.withLock { $0.downloadRequests } == requestCount)
        #expect(fixture.server.log.isEmpty)
        await engine.shutdown()
    }

    @Test func quarkCapacityReadsByteCountsWithoutWritesAndAllowsUsedAboveTotal() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let client = stub.makeClient()
        let capacity = try await client.capacity()
        #expect(capacity.total == 100)
        #expect(capacity.used == 40)
        let requests = stub.state.withLock { $0.capacityRequests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.host == "drive-pc.quark.cn")
        #expect(request.query == ["pr": "ucpro", "fr": "pc", "uc_param_str": ""])
        stub.state.withLock { $0.capacityPayload = #"{"total_capacity":0,"use_capacity":9223372036854775807}"# }
        let exceeded = try await client.capacity()
        #expect(exceeded.total == 0)
        #expect(exceeded.used == Int64.max)
        #expect(stub.state.withLock { $0.saves.isEmpty && $0.queried.isEmpty })
    }

    @Test(arguments: [
        #"{}"#, #"{"total_capacity":100}"#, #"{"total_capacity":null,"use_capacity":0}"#,
        #"{"total_capacity":-1,"use_capacity":0}"#, #"{"total_capacity":1,"use_capacity":-1}"#,
        #"{"total_capacity":"100","use_capacity":0}"#, #"{"total_capacity":100,"use_capacity":1.5}"#,
        #"{"total_capacity":true,"use_capacity":0}"#,
        #"{"total_capacity":9223372036854775808,"use_capacity":0}"#,
    ])
    func quarkCapacityRejectsMissingNegativeAndNonIntegerValues(_ payload: String) async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock { $0.capacityPayload = payload }
        let client = stub.makeClient()
        do {
            _ = try await client.capacity()
            Issue.record("Invalid capacity response must fail without defaulting to zero.")
        } catch QuarkError.invalidResponse {}
    }

    @Test func quarkCapacityFailureExplainsServerLimitWithoutAssumingAccountIsFull() throws {
        let original = "capacity limit[{0}]"
        let failure = QuarkError.serviceFailure(code: "32003", message: original)
        let description = try #require(failure.errorDescription)
        #expect(description.contains("空间不足"))
        #expect(description.contains("32003"))
        #expect(description.contains("官方页面检查"))
        #expect(description.contains("空间权益"))
        #expect(!description.contains("空间已满"))
        #expect(!description.contains("{0}"))
        #expect(QuarkError.serviceCode("32003").errorDescription == description)
        // 用户说明不显示未替换的模板，但错误对象仍保留服务端原始原因。
        #expect(failure == .serviceFailure(code: "32003", message: original))
    }

    @Test func quarkUnknownFailurePreservesCodeAndReasonWithoutRawTemplateParameters() {
        let templated = QuarkError.serviceFailure(code: "99999", message: "request limit[{0}], retry after {12}")
        #expect(templated.errorDescription == "夸克请求未成功：request limit[参数未提供], retry after 参数未提供（业务码 99999）。")
        #expect(QuarkError.serviceFailure(code: "99998", message: "请明天再试").errorDescription ==
                "夸克请求未成功：请明天再试（业务码 99998）。")
        #expect(QuarkError.serviceCode("99997").errorDescription == "夸克请求未成功（业务码 99997），请稍后重试。")
    }

    private func quarkSelection(_ disk: QuarkNetdisk) async throws -> (DiskShareSession, [RemoteEntry]) {
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let root = try await disk.listShare(session, directory: nil)
        let docs = try #require(root.first { $0.name == "docs" })
        let children = try await disk.listShare(session, directory: docs)
        let readme = try #require(children.first { !$0.isDirectory })
        let nested = try #require(children.first { $0.isDirectory })
        let report = try #require(try await disk.listShare(session, directory: nested).first)
        return (session, [readme, report])
    }

    @Test func quarkKnownSelectionPathsAvoidUnrelatedModelTreeAndReuseDirectoryCache() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock {
            $0.shareDirectoryOverrides = [
                "0": [("comfy", "ComfyUI", true), ("models", "models", true), ("guide", "guide.txt", false)],
                "comfy": [("nodes", "ComfyUI_GJJ_Nodes", true)],
                "nodes": [("readme", "README.md", false), ("requirements", "requirements-optional.txt", false)],
                "models": [("huge-tree", "huge-tree", true)],
            ]
        }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let entries = [
            RemoteEntry(reference: .quark(fid: "guide"), name: "guide.txt", isDirectory: false, size: 12, relativeDirectory: ""),
            RemoteEntry(reference: .quark(fid: "readme"), name: "README.md", isDirectory: false, size: 12, relativeDirectory: "ComfyUI/ComfyUI_GJJ_Nodes"),
            RemoteEntry(reference: .quark(fid: "requirements"), name: "requirements-optional.txt", isDirectory: false, size: 12, relativeDirectory: "ComfyUI/ComfyUI_GJJ_Nodes"),
        ]
        try await disk.prepareTransfer(session, entries: entries)
        #expect(stub.state.withLock { $0.requestedShareParents } == ["0", "comfy", "nodes"])
        try await disk.prepareTransfer(session, entries: entries)
        let result = try await disk.submitTransfer(session, entries: entries,
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { _ in }
        await disk.releaseShare(session)
        #expect(result.completed && result.batches?.count == 2)
        #expect(stub.state.withLock { $0.requestedShareParents } == ["0", "comfy", "nodes"])
        #expect(stub.state.withLock { !$0.requestedShareParents.contains("models") })
    }

    @Test func quarkMissingKnownSelectionPathDoesNotFallBackToScanning() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        do {
            try await disk.prepareTransfer(session, entries: [RemoteEntry(reference: .quark(fid: "readme"),
                name: "readme.txt", isDirectory: false, size: 12, relativeDirectory: "missing/subdirectory")])
            Issue.record("known path mismatch should fail")
        } catch QuarkError.invalidSelection {}
        await disk.releaseShare(session)
        #expect(stub.state.withLock { $0.requestedShareParents } == ["0"])
        #expect(stub.state.withLock { $0.saves.isEmpty })
    }

    @Test func quarkLegacySelectionWithoutPathStillRestoresFromShareTree() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let entry = RemoteEntry(reference: .quark(fid: "report"), name: "readme.txt", isDirectory: false, size: 12)
        try await disk.prepareTransfer(session, entries: [entry])
        let result = try await disk.submitTransfer(session, entries: [entry],
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { _ in }
        await disk.releaseShare(session)
        #expect(result.completed && result.batches?.first?.relativeDirectory == "docs/nested")
        #expect(stub.state.withLock { $0.requestedShareParents } == ["0", "docs", "nested"])
    }

    @Test func quarkCancelledPreparationDoesNotReadDirectoryTree() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let entry = RemoteEntry(reference: .quark(fid: "readme"), name: "readme.txt", isDirectory: false, size: 12, relativeDirectory: "docs")
        let task = Task { try await disk.prepareTransfer(session, entries: [entry]) }
        task.cancel()
        do {
            try await task.value
            Issue.record("cancelled preparation should stop")
        } catch is CancellationError {}
        await disk.releaseShare(session)
        #expect(stub.state.withLock { $0.requestedShareParents.isEmpty })
    }

    @Test func quarkVirtualShareRootAcceptsPublisherParentButSavesFromRootZero() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock { $0.shareRootParentFID = "publisher-real-parent" }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let root = try await disk.listShare(session, directory: nil)
        #expect(root.count == 2)
        let file = try #require(root.first { !$0.isDirectory })
        #expect(file.relativeDirectory == "")
        let result = try await disk.submitTransfer(session, entries: [file],
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { _ in }
        await disk.releaseShare(session)
        #expect(result.completed)
        #expect(stub.state.withLock { $0.saveSourceParents } == ["0"])
    }

    @Test func quarkShareTokenQueryPreservesPlusSlashAndEquals() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let token = "synthetic+base64/token=="
        stub.state.withLock { $0.shareToken = token }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        _ = try await disk.listShare(session, directory: nil)
        await disk.releaseShare(session)
        let state = stub.state.withLock { $0 }
        #expect(state.lastDetailToken == token)
        #expect(state.lastDetailQuery?.contains("+") == false)
        #expect(state.lastDetailQuery?.contains("%2B") == true)
    }

    @Test func quarkShareSubdirectoryStillRejectsForeignParent() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock { $0.shareParentOverrides["docs"] = "foreign-parent" }
        let disk = stub.makeDisk()
        let session = try await disk.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        let docs = try #require(try await disk.listShare(session, directory: nil).first { $0.id == "docs" })
        do {
            _ = try await disk.listShare(session, directory: docs)
            Issue.record("foreign share parent must fail")
        } catch QuarkError.invalidResponse {}
        await disk.releaseShare(session)
    }

    @Test func quarkAccountRootStillRejectsForeignParent() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        stub.state.withLock {
            $0.folders["0"] = [("child", "child")]
            $0.accountParentOverrides["0"] = "foreign-parent"
        }
        let disk = stub.makeDisk()
        do {
            _ = try await disk.listDirectory(nil)
            Issue.record("foreign account parent must fail")
        } catch QuarkError.invalidResponse {}
    }

    @Test func quarkPartialSelectionPreservesSameNamesInDifferentDirectories() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        defer { Task { await disk.releaseShare(session) } }
        #expect(entries.map(\.relativeDirectory) == ["docs", "docs/nested"])
        #expect(entries.map(\.name) == ["readme.txt", "readme.txt"])
        let ledger = OSAllocatedUnfairLock<[TransferProgress]>(initialState: [])
        let result = try await disk.submitTransfer(session, entries: entries,
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { progress in
                ledger.withLock { $0.append(progress) }
            }
        let state = stub.state.withLock { $0 }
        #expect(state.saves.count == 2)
        #expect(state.saves[0].fids == ["readme"])
        #expect(state.saves[1].fids == ["report"])
        #expect(state.folders["owned"]?.first?.name == "docs")
        let docs = try #require(state.folders["owned"]?.first?.fid)
        #expect(state.folders[docs]?.first?.name == "nested")
        #expect(state.saves[0].destination == docs)
        #expect(state.saves[1].destination == state.folders[docs]?.first?.fid)
        #expect(result.completed && result.batches?.allSatisfy(\.completed) == true)
        for index in 0..<2 {
            let history = ledger.withLock { $0.compactMap { $0.batches?[index] } }
            let intent = try #require(history.firstIndex { $0.submitted && $0.taskID == nil })
            let receipt = try #require(history.firstIndex { $0.taskID != nil && !$0.completed })
            let complete = try #require(history.firstIndex { $0.completed })
            #expect(intent < receipt && receipt < complete)
        }
    }

    @Test func quarkResumesKnownBatchAndSubmitsOnlyRemainingBatch() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        let ledger = OSAllocatedUnfairLock<TransferProgress?>(initialState: nil)
        _ = stub.state.withLock { $0.failQueries.insert("task-1") }
        do {
            _ = try await disk.submitTransfer(session, entries: entries,
                to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { progress in ledger.withLock { $0 = progress } }
            Issue.record("expected interrupted polling")
        } catch {}
        let previous = try #require(ledger.withLock { $0 })
        #expect(previous.batches?[0].taskID == "task-1")
        #expect(previous.batches?[1].submitted == false)
        await disk.releaseShare(session)
        let resumed = stub.makeDisk()
        let reopened = try await resumed.openShare(DiskShareLink(provider: .quark, code: "test"), password: nil)
        try await resumed.prepareTransfer(reopened, entries: [entries[1]])
        let result = try await resumed.submitTransfer(reopened, entries: entries,
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: previous) { progress in ledger.withLock { $0 = progress } }
        await resumed.releaseShare(reopened)
        let state = stub.state.withLock { $0 }
        #expect(result.completed)
        #expect(state.saves.count == 2)
        #expect(state.queried == ["task-1", "task-1", "task-2"])
        #expect(state.folders.count == 3)
    }

    @Test func quarkUnknownSubmissionNeverRepeatsOrStartsNextBatch() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        _ = stub.state.withLock { $0.loseReceipts.insert(1) }
        let ledger = OSAllocatedUnfairLock<TransferProgress?>(initialState: nil)
        do {
            _ = try await disk.submitTransfer(session, entries: entries,
                to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { progress in ledger.withLock { $0 = progress } }
            Issue.record("expected lost receipt")
        } catch {}
        let previous = try #require(ledger.withLock { $0 })
        #expect(previous.batches?[0].submitted == true && previous.batches?[0].taskID == nil)
        do {
            _ = try await disk.submitTransfer(session, entries: entries,
                to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: previous) { progress in ledger.withLock { $0 = progress } }
            Issue.record("unknown submission should stop")
        } catch TransferCheckError.unconfirmedTransfer {}
        await disk.releaseShare(session)
        #expect(stub.state.withLock { $0.saves.count } == 1)
        #expect(stub.state.withLock { $0.queried.isEmpty })
    }

    @Test func quarkCompletedFirstBatchSkipsItWhenRestoringSecond() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        let ledger = OSAllocatedUnfairLock<TransferProgress?>(initialState: nil)
        do {
            _ = try await disk.submitTransfer(session, entries: entries,
                to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { progress in
                    ledger.withLock { $0 = progress }
                    if progress.batches?[0].completed == true, progress.batches?[1].destination == nil { throw CancellationError() }
                }
            Issue.record("expected interruption between batches")
        } catch is CancellationError {}
        let previous = try #require(ledger.withLock { $0 })
        #expect(previous.batches?[0].completed == true && previous.batches?[1].submitted == false)
        let result = try await disk.submitTransfer(session, entries: entries,
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: previous) { progress in ledger.withLock { $0 = progress } }
        await disk.releaseShare(session)
        #expect(result.completed)
        #expect(stub.state.withLock { $0.saves.count } == 2)
        #expect(stub.state.withLock { $0.queried } == ["task-1", "task-2"])
    }

    @Test func quarkReceiptWriteFailureRetainsTaskIDForRetry() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        let fixture = Fixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.netdisks[.quark] = disk
        await coordinator.start()
        let file = fixture.store.fileURL
        let backup = file.appendingPathExtension("before-receipt")
        stub.state.withLock { state in
            state.afterSave = {
                try FileManager.default.moveItem(at: file, to: backup)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
        }
        let job = coordinator.addJob(session: session, entries: entries)
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        let progress = try #require(coordinator.job(job.id)?.transferProgress)
        #expect(progress.batches?[0].taskID == "task-1")
        #expect(stub.state.withLock { $0.saves.count } == 1)
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("blocked-receipt"))
        try FileManager.default.moveItem(at: backup, to: file)
        await coordinator.retry(job.id)
        try await waitUntil("all restored Quark batches completed") { coordinator.job(job.id)?.transferProgress?.completed == true }
        // 此桩只模拟转存协议，不提供下载文件；等目录核对自然结束后再关停。
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(stub.state.withLock { $0.saves.count } == 2)
        #expect(stub.state.withLock { $0.queried } == ["task-1", "task-2"])
        await disk.releaseShare(session)
        await coordinator.shutdown()
    }

    @Test func quarkSelectedParentSuppressesAlreadyIncludedDescendants() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, children) = try await quarkSelection(disk)
        let root = try await disk.listShare(session, directory: nil)
        let docs = try #require(root.first { $0.id == "docs" })
        let result = try await disk.submitTransfer(session, entries: [docs] + children,
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { _ in }
        await disk.releaseShare(session)
        #expect(result.batches?.count == 1)
        #expect(stub.state.withLock { $0.saves.first?.fids } == ["docs"])
        #expect(stub.state.withLock { $0.saves.first?.destination } == "owned")
    }

    @Test func quarkPartialDirectoryAndSiblingFileShareCorrectParentBatch() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, leaves) = try await quarkSelection(disk)
        let root = try await disk.listShare(session, directory: nil)
        let docs = try #require(root.first { $0.id == "docs" })
        let children = try await disk.listShare(session, directory: docs)
        let nested = try #require(children.first { $0.id == "nested" })
        let result = try await disk.submitTransfer(session, entries: [leaves[0], nested],
            to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: nil) { _ in }
        await disk.releaseShare(session)
        #expect(result.completed && result.batches?.count == 1)
        #expect(result.batches?.first?.relativeDirectory == "docs")
        #expect(stub.state.withLock { $0.saves.first?.fids } == ["nested", "readme"])
        #expect(stub.state.withLock { $0.saves.count } == 1)
    }

    @Test func quarkSavedDestinationMustRemainInsideOwnedRoot() async throws {
        let stub = QuarkAPIStub()
        defer { FileProtocol.removeAPI(stub.id) }
        let disk = stub.makeDisk()
        let (session, entries) = try await quarkSelection(disk)
        let previous = TransferProgress(batches: [TransferBatchProgress(relativeDirectory: "docs", entryIDs: [entries[0].id],
            destination: .quark(fid: "outside-owned-root"))])
        do {
            _ = try await disk.submitTransfer(session, entries: [entries[0]],
                to: TransferDirectory(reference: .quark(fid: "owned"), name: "TASK"), previous: previous) { _ in }
            Issue.record("foreign destination should fail")
        } catch QuarkError.invalidSelection {}
        await disk.releaseShare(session)
        #expect(stub.state.withLock { $0.saves.isEmpty })
        #expect(stub.state.withLock { $0.folders.count } == 1)
    }

    @Test func quarkBatchProgressKeepsLegacySingleTaskCompatibility() throws {
        let legacy = try JSONDecoder().decode(TransferProgress.self,
            from: Data(#"{"taskID":"old-task","submitted":true,"completed":false}"#.utf8))
        #expect(legacy.batches == nil && !legacy.needsSubmission)
        let batch = TransferProgress(submitted: true, batches: [TransferBatchProgress(relativeDirectory: "docs", entryIDs: ["f1"],
            destination: .quark(fid: "owned-child"), submitted: true, taskID: "batch-task")])
        #expect(try JSONDecoder().decode(TransferProgress.self, from: JSONEncoder().encode(batch)) == batch)
    }

    private let share: [String: Data] = [
        "a.bin": randomData(300_000),
        "docs/readme.txt": randomData(1_000),
        "docs/2024/report.pdf": randomData(200_000),
        "empty.txt": Data(),
    ]

    @Test func persistenceFailurePreventsRemoteMutation() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        // 用目录占用任务文件名，稳定模拟原子写入失败；不依赖运行用户的权限级别。
        let saved = fixture.store.fileURL
        try FileManager.default.moveItem(at: saved, to: saved.appendingPathExtension("saved"))
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(fixture.netdisk.operations.isEmpty)
        #expect(coordinator.job(job.id)?.transferProgress == nil)
    }

    @Test func failedIntentWriteCanRetryWithoutSubmittingTwice() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let saved = fixture.store.fileURL
        let backup = saved.appendingPathExtension("before-intent")
        fixture.netdisk.beforeNextShareOpen {
            try FileManager.default.moveItem(at: saved, to: backup)
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        }
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.transferProgress == nil)
        #expect(!fixture.netdisk.operations.contains(.transfer(job.remoteDirectory)))
        try FileManager.default.moveItem(at: saved, to: saved.appendingPathExtension("blocked"))
        try FileManager.default.moveItem(at: backup, to: saved)
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.netdisk.operations.count { $0 == .createDirectory(job.remoteDirectory) } == 1)
        #expect(fixture.netdisk.operations.count { $0 == .transfer(job.remoteDirectory) } == 1)
    }

    @Test func downloadsTransferredFilesPreservingStructure() async throws {
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        var completed: [Job.ID] = []
        coordinator.onJobCompleted = { completed.append($0.id) }

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        #expect(coordinator.jobs.map(\.id) == [job.id])
        try await coordinator.waitForPhase(.completed, of: job.id)

        for (path, data) in share {
            #expect(fixture.contents(path) == data, "\(path)")
        }
        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.count == 4)
        #expect(finished.files.allSatisfy { $0.isCompleted })
        #expect(Set(finished.files.map(\.remotePath)) == Set(share.keys.map { job.remoteDirectory + "/" + $0 }))
        #expect(coordinator.progress(of: finished).fractionCompleted == 1)
        #expect(completed == [job.id])
        #expect(fixture.netdisk.operations.prefix(4) == [
            .createDirectory(job.remoteDirectory), .openShare, .transfer(job.remoteDirectory), .list(job.remoteDirectory),
        ])
        // 清理默认关闭。
        #expect(!finished.isCleanedUp)
        #expect(fixture.netdisk.remotePaths().count == 4)
        #expect(try fixture.store.load() == coordinator.jobs)
    }

    @Test func cleanupDeletesJobDirectoryWhenEnabled() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)

        #expect(coordinator.job(job.id)?.isCleanedUp == true)
        #expect(fixture.netdisk.operations.last == .delete([job.remoteDirectory]))
        #expect(fixture.netdisk.remotePaths().isEmpty)
    }

    @Test func cleanupFailureOnlyWarns() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        fixture.netdisk.failNextDelete()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)

        let finished = try #require(coordinator.job(job.id))
        #expect(!finished.isCleanedUp)
        #expect(finished.warning?.isEmpty == false)
        #expect(finished.error == nil)
    }

    @Test func uncertainTransferRetryDoesNotSubmitAgain() async throws {
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.failNextTransfer()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(!fixture.netdisk.remotePaths().isEmpty)
        #expect(coordinator.job(job.id)?.transferProgress?.submitted == true)
        #expect(coordinator.job(job.id)?.transferProgress?.completed == false)
        let operations = fixture.netdisk.operations

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error == TransferCheckError.unconfirmedTransfer.errorDescription)
        #expect(fixture.netdisk.operations == operations)
        #expect(fixture.netdisk.deletes.isEmpty)
    }

    @Test func downloadRetryOnlyRestartsFailedFiles() async throws {
        let fixture = Fixture(share: ["good.bin": randomData(50_000), "bad.bin": randomData(50_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setFailing(["/bad.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.download), of: added.id)
        let failed = try #require(coordinator.job(added.id))
        #expect(failed.error?.contains("500") == true)
        #expect(failed.files.filter(\.isCompleted).map(\.relativePath) == ["good.bin"])

        fixture.server.setFailing([])
        await coordinator.retry(added.id)
        try await coordinator.waitForPhase(.completed, of: added.id)

        let remoteDirectory = failed.remoteDirectory
        #expect(fixture.server.requests(for: remoteDirectory + "/good.bin") == 1)
        #expect(fixture.server.requests(for: remoteDirectory + "/bad.bin") == 2)
        #expect(fixture.contents("bad.bin") == fixture.netdisk.data(at: remoteDirectory + "/bad.bin"))
    }

    @Test func pauseAndResume() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000), "b.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = coordinator.job(job.id), job.files.count == 2 else { return false }
            return coordinator.progress(of: job).receivedBytes >= 400_000
        }

        await coordinator.pause(job.id)
        let paused = try #require(coordinator.job(job.id))
        #expect(paused.isPaused)
        #expect(paused.phase == .downloading)
        try await waitUntil("files paused") {
            paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused }
        }
        #expect(try fixture.store.load().first?.isPaused == true)

        fixture.server.setStalled(false)
        await coordinator.resume(job.id)
        #expect(coordinator.job(job.id)?.isPaused == false)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
        #expect(fixture.contents("b.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/b.bin"))
    }

    @Test func activityMatchesProgressOfCompletedAndRunningFiles() async throws {
        let fixture = Fixture(share: ["small.bin": randomData(1_000), "big.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalling(["/big.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        let activity = coordinator.activity(of: added.id)
        try await waitUntil("small file completed and big file running") {
            guard let job = coordinator.job(added.id), job.files.contains(where: \.isCompleted) else { return false }
            return activity.isRunning && activity.progress.receivedBytes > 1_000 && activity.progress == coordinator.progress(of: job)
        }
        #expect(activity.progress.totalBytes == 401_000)

        fixture.server.setStalling([])
        try await coordinator.waitForPhase(.completed, of: added.id)
        let finished = try #require(coordinator.job(added.id))
        try await waitUntil("activity complete") {
            !activity.isRunning && activity.progress == coordinator.progress(of: finished)
        }
        #expect(activity.progress.receivedBytes == 401_000)
        #expect(activity.progress.bytesPerSecond == 0)
    }

    @Test func failsOnlyAfterOtherFilesStop() async throws {
        let fixture = Fixture(share: ["bad.bin": randomData(1_000), "slow.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setFailing(["/bad.bin"])
        fixture.server.setStalling(["/slow.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        let activity = coordinator.activity(of: added.id)
        try await waitUntil("bad file failed while slow file runs") {
            guard let job = coordinator.job(added.id), job.files.count == 2 else { return false }
            let states = job.files.map { coordinator.downloads[$0.id]?.state }
            return states.contains { if case .failed = $0 { true } else { false } } && states.contains(DownloadState.running)
        }
        try await waitUntil("activity running") { activity.isRunning }
        #expect(coordinator.job(added.id)?.phase == .downloading)

        fixture.server.setStalling([])
        try await coordinator.waitForPhase(.failed(.download), of: added.id)
        let failed = try #require(coordinator.job(added.id))
        #expect(failed.error == DownloadFailure.httpStatus(500, message: "").message)
        #expect(failed.files.filter(\.isCompleted).map(\.relativePath) == ["slow.bin"])
        try await waitUntil("activity stopped") {
            !activity.isRunning && activity.progress == coordinator.progress(of: failed)
        }
    }

    @Test func removeCancelsDownloadsAndKeepsCompletedFiles() async throws {
        let fixture = Fixture(share: ["done.bin": Data(), "big.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        var isRunning = false
        coordinator.onRunningChanged = { isRunning = $0 }
        await coordinator.start()
        fixture.server.setStalled(true)

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("one file completed and one running") {
            guard let job = coordinator.job(job.id) else { return false }
            return job.files.contains(where: \.isCompleted)
                && job.files.contains { coordinator.downloads[$0.id]?.state == .running }
        }
        let big = try #require(coordinator.job(job.id)?.files.first { $0.relativePath == "big.bin" })

        await coordinator.remove(job.id)
        fixture.server.setStalled(false)

        #expect(coordinator.jobs.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        #expect(coordinator.downloads[big.id] == nil)
        #expect(!isRunning)
        #expect(FileManager.default.fileExists(atPath: fixture.downloads.appending(path: "done.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.downloads.path)
        #expect(!leftovers.contains { $0.hasSuffix(".ferrydownload") })
        #expect(fixture.netdisk.operations.last == .delete([job.remoteDirectory]))
        #expect(fixture.netdisk.remotePaths().isEmpty)
    }

    @Test func removeTrashingFilesKeepsUserFiles() async throws {
        let fixture = Fixture(share: ["Show/a.bin": randomData(1000), "Show/S1/b.bin": randomData(1000)])
        // 下载目录中原来就有同名目录和用户自己的文件。
        let show = fixture.downloads.appending(path: "Show")
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: show.appending(path: "mine.txt"))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        let failed = await coordinator.remove(job.id, trashingFiles: true)

        #expect(failed.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: show.path) == ["mine.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 2)
    }

    /// 移除等待首文件取消时，另一文件刚完成也必须按最终实际路径移入废纸篓。
    @Test func removeTrashesFileCompletingDuringCancellationAndKeepsUnrelatedNames() async throws {
        let names = ["a-blocked.bin", "b-finish.bin", "c-partial.bin"]
        let fixture = Fixture(disk: Dictionary(uniqueKeysWithValues: names.map { ("/" + $0, randomData(400_000)) }))
        let unrelated = Data("user's existing file".utf8)
        let existing = fixture.downloads.appendingPathComponent("b-finish.bin")
        try unrelated.write(to: existing)
        fixture.server.setStalling(["/b-finish.bin", "/c-partial.bin"])
        let source = RemovalGateSource(base: FileServerSource(server: fixture.server))
        defer { source.open(); fixture.server.setStalling([]) }
        let entries = names.enumerated().map { index, name in
            RemoteEntry(fsID: Int64(index + 1), name: name, path: "/" + name, isDirectory: false, size: 400_000)
        }
        var job = Job(netdiskEntries: entries)
        job.accountKey = Fixture.account
        job.phase = .downloading
        job.files = entries.map { JobFile(remotePath: $0.path, relativePath: $0.name, size: $0.size) }
        try fixture.store.save([job])
        let engine = fixture.makeEngine(source: source)
        let coordinator = JobCoordinator(engine: engine, store: fixture.store,
                                         settings: FerrySettings(cleanupAfterDownload: false, maxConcurrentFiles: 3),
                                         downloadFolder: DownloadFolder(url: fixture.downloads),
                                         trashItem: Fixture.trashItem(into: fixture.trash), baseConfiguration: Fixture.configuration)
        coordinator.netdisks[.baidu] = fixture.netdisk
        await coordinator.start()
        let partial = job.files[2]
        try await waitUntil("both nongated files to receive partial bytes") {
            source.hasEntered && job.files[1...].allSatisfy { (coordinator.downloads[$0.id]?.receivedBytes ?? 0) > 0 }
        }
        let jobID = job.id
        let removal = Task { await coordinator.remove(jobID, trashingFiles: true, cleanupConfirmed: false) }
        try await waitUntil("first file cancellation to hold removal") { source.wasCancelled }
        fixture.server.setStalling(["/c-partial.bin"])
        try await waitUntil("second file to finish while removal is waiting") {
            coordinator.job(jobID)?.files[1].localURL != nil
        }
        let completedURL = try #require(coordinator.job(jobID)?.files[1].localURL)
        #expect(completedURL.lastPathComponent == "b-finish (1).bin")
        #expect(coordinator.job(jobID)?.files[2].localURL == nil)
        source.open()
        #expect(await removal.value == [])
        #expect(coordinator.jobs.isEmpty)
        #expect(try Data(contentsOf: existing) == unrelated)
        #expect(!FileManager.default.fileExists(atPath: completedURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.downloads.appendingPathComponent(partial.relativePath).path))
        let trashed = try FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil)
        #expect(trashed.count == 1)
        let trashedURL = try #require(trashed.first)
        #expect(try Data(contentsOf: trashedURL) == fixture.netdisk.data(at: "/b-finish.bin"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.downloads.path) == ["b-finish.bin"])
        await coordinator.shutdown()
    }

    @Test func restoresDownloadsAfterRestart() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)

        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = first.job(job.id), !job.files.isEmpty else { return false }
            return first.progress(of: job).receivedBytes > 0
        }
        await first.shutdown()

        // 中断在转存阶段的任务。
        var interrupted = Job(link: FakeNetdisk.link, password: nil, entries: fixture.netdisk.rootEntries(), transferFolder: "/Ferry")
        interrupted.createdAt = .distantPast
        try fixture.store.save(try fixture.store.load() + [interrupted])

        fixture.server.setStalled(false)
        let second = fixture.makeCoordinator()
        await second.start()

        #expect(second.job(interrupted.id)?.phase == .failed(.transfer))
        #expect([.downloading, .completed].contains(second.job(job.id)?.phase))
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
        let ranges = fixture.server.log.filter { $0 == job.remoteDirectory + "/a.bin" }
        #expect(ranges.count == 2)
    }

    @Test func restoreRecordsDownloadsCompletedBeforeSave() async throws {
        let fixture = Fixture(share: ["small.bin": randomData(1_000), "big.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        first.saveDelay = .seconds(60)
        await first.start()
        fixture.server.setStalling(["/big.bin"])
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("small file completed") {
            first.job(job.id)?.files.first { $0.relativePath == "small.bin" }?.isCompleted == true
        }
        // 完成状态还没写入任务列表，引擎仍保留它。保留这时的任务列表和小文件的完成记录，模拟应用在两步之间退出。
        // 大文件的记录一直在更新，不复制它：退出后它的记录就是最终的。
        let small = try #require(first.job(job.id)?.files.first { $0.relativePath == "small.bin" })
        let smallState = StateStore(directory: fixture.stateDirectory).fileURL(for: small.id)
        let savedJobs = try Data(contentsOf: fixture.store.fileURL)
        let savedState = try Data(contentsOf: smallState)
        await first.shutdown()
        try await waitUntil("engine forgets small file") { !FileManager.default.fileExists(atPath: smallState.path) }
        try savedState.write(to: smallState)
        try savedJobs.write(to: fixture.store.fileURL)
        #expect(try fixture.store.load().first?.files.contains(where: \.isCompleted) == false)

        fixture.server.setStalling([])
        let second = fixture.makeCoordinator()
        await second.start()
        let restored = try #require(second.job(job.id)?.files.first { $0.id == small.id })
        #expect(restored.isCompleted)
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.server.requests(for: job.remoteDirectory + "/small.bin") == 1)
        #expect(fixture.contents("big.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/big.bin"))
    }

    @Test func restoresPausedJobAsPaused() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("running") {
            first.job(job.id)?.files.contains { first.downloads[$0.id]?.state == .running } ?? false
        }
        await first.pause(job.id)
        await first.shutdown()
        fixture.server.setStalled(false)

        let second = fixture.makeCoordinator()
        await second.start()
        let restored = try #require(second.job(job.id))
        #expect(restored.isPaused)
        #expect(restored.files.allSatisfy { second.downloads[$0.id]?.state == .paused })

        await second.resume(job.id)
        try await second.waitForPhase(.completed, of: job.id)
    }

    @Test func unreadableJobListKeepsDownloadsUntouched() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = first.job(job.id), !job.files.isEmpty else { return false }
            return first.progress(of: job).receivedBytes > 0
        }
        await first.shutdown()
        fixture.server.setStalled(false)
        let saved = try Data(contentsOf: fixture.store.fileURL)
        try Data("{".utf8).write(to: fixture.store.fileURL)
        let stateFiles = try fixture.stateFiles()
        #expect(!stateFiles.isEmpty)
        let requests = fixture.server.log.count

        let second = fixture.makeCoordinator()
        await second.start()
        #expect(second.jobs.isEmpty)
        #expect(second.loadWarning?.contains("jobs.json.corrupt-") == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix("jobs.json.corrupt-") }
        #expect(backups.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try fixture.stateFiles() == stateFiles)
        #expect(fixture.server.log.count == requests)
        await second.shutdown()

        // 用户把备份改回原名后，下载从断点继续。
        try saved.write(to: fixture.store.fileURL)
        let third = fixture.makeCoordinator()
        await third.start()
        #expect(third.loadWarning == nil)
        try await third.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
    }

    @Test func failsWhenTransferredFilesAreMissing() async throws {
        let fixture = Fixture(share: ["docs/a.bin": randomData(1_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.setNextListing([])

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("没有找到文件") == true)

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("docs/a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/docs/a.bin"))
    }

    @Test func incompleteNonemptyTransferRetainsReceiptAndRetriesListingWithoutResubmitting() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10), "b.bin": randomData(20)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        fixture.netdisk.setNextListing([RemoteFile(path: job.remoteDirectory + "/a.bin", size: 10, fsID: 1)])

        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        let failed = try #require(coordinator.job(job.id))
        #expect(failed.error == TransferCheckError.incompleteTransfer("b.bin").errorDescription)
        #expect(failed.transferProgress?.completed == true)
        #expect(failed.files.isEmpty)
        #expect(fixture.netdisk.deletes.isEmpty)
        #expect(fixture.contents("a.bin") == nil)
        let submissions = fixture.netdisk.operations.filter { if case .transfer = $0 { true } else { false } }.count
        let opens = fixture.netdisk.operations.filter { $0 == .openShare }.count

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(coordinator.job(job.id)?.files.count == 2)
        #expect(fixture.netdisk.operations.filter { if case .transfer = $0 { true } else { false } }.count == submissions)
        #expect(fixture.netdisk.operations.filter { $0 == .openShare }.count == opens)
    }

    @Test func transferSizeMismatchDoesNotDownloadOrCleanUp() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        fixture.netdisk.setNextListing([RemoteFile(path: job.remoteDirectory + "/a.bin", size: 9, fsID: 1)])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error == TransferCheckError.incompleteTransfer("a.bin").errorDescription)
        #expect(coordinator.job(job.id)?.files.isEmpty == true)
        #expect(fixture.netdisk.deletes.isEmpty)
        #expect(fixture.contents("a.bin") == nil)
    }

    @Test func manifestWriteFailureStopsSubmissionAndRetryPersistsManifestBeforeTransfer() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let file = fixture.store.fileURL
        let backup = file.appendingPathExtension("before-manifest")
        fixture.netdisk.beforeNextShareOpen {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.transferManifest == [TransferManifestEntry(relativePath: "a.bin", size: 10)])
        #expect(coordinator.job(job.id)?.transferProgress == nil)
        #expect(!fixture.netdisk.operations.contains { if case .transfer = $0 { true } else { false } })
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("blocked-manifest"))
        try FileManager.default.moveItem(at: backup, to: file)
        // 重试一开始先保存包括内存清单的任务，再获取会话；此处观察提交前的磁盘内容。
        let store = fixture.store
        fixture.netdisk.beforeNextShareOpen {
            let persisted = try #require(store.load().first { $0.id == job.id })
            #expect(persisted.transferManifest == [TransferManifestEntry(relativePath: "a.bin", size: 10)])
            #expect(persisted.transferProgress == nil)
        }
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.netdisk.operations.filter { if case .transfer = $0 { true } else { false } }.count == 1)
        await coordinator.shutdown()
    }

    @Test func completedDirectoryTransferRestoresFromManifestAfterShareExpires() async throws {
        let fixture = Fixture(share: ["docs/a.bin": randomData(10), "docs/b.bin": randomData(20)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.netdisk.setNextListing([])
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await first.waitForPhase(.failed(.transfer), of: job.id)
        let saved = try #require(first.job(job.id))
        #expect(saved.transferProgress?.completed == true)
        #expect(saved.transferManifest == [TransferManifestEntry(relativePath: "docs/a.bin", size: 10),
                                           TransferManifestEntry(relativePath: "docs/b.bin", size: 20)])
        await first.shutdown()
        // 重启后的原分享已失效；已有清单和完成回执应完全脱离分享会话恢复。
        fixture.netdisk.beforeNextShareOpen { throw QuarkError.shareUnavailable }
        let opens = fixture.netdisk.operations.filter { $0 == .openShare }.count
        let second = fixture.makeCoordinator()
        await second.start()
        await second.retry(job.id)
        try await second.waitForPhase(.completed, of: job.id)
        #expect(second.job(job.id)?.files.count == 2)
        #expect(fixture.netdisk.operations.filter { $0 == .openShare }.count == opens)
        #expect(fixture.contents("docs/a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/docs/a.bin"))
        await second.shutdown()
    }

    @Test func legacyDirectoryReceiptWithoutManifestCannotConfirmExpiredShare() async throws {
        let fixture = Fixture(share: ["docs/a.bin": randomData(10)])
        var job = try await fixture.makeTransferredJob()
        job.phase = .failed(.transfer)
        job.files = []
        #expect(job.transferManifest == nil)
        try fixture.store.save([job])
        fixture.netdisk.beforeNextShareOpen { throw QuarkError.shareUnavailable }
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        let failed = try #require(coordinator.job(job.id))
        #expect(failed.error?.contains("旧任务没有转存文件清单") == true)
        #expect(failed.transferProgress?.completed == true)
        #expect(failed.transferManifest == nil)
        #expect(failed.files.isEmpty)
        #expect(fixture.netdisk.deletes.isEmpty)
        #expect(fixture.netdisk.operations.filter { if case .transfer = $0 { true } else { false } }.count == 1)
        // 原分享恢复后可补建清单，只核对既有结果，不重提旧转存。
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(coordinator.job(job.id)?.transferManifest == [TransferManifestEntry(relativePath: "docs/a.bin", size: 10)])
        #expect(fixture.netdisk.operations.filter { if case .transfer = $0 { true } else { false } }.count == 1)
        await coordinator.shutdown()
    }

    @Test func completedReceiptCannotHideMissingFileInsideSelectedDirectory() async throws {
        let fixture = Fixture(share: ["docs/a.bin": randomData(10), "docs/b.bin": randomData(20),
                                      "unselected/large.bin": randomData(30)])
        let entries = fixture.netdisk.rootEntries().filter { $0.name == "docs" }
        var job = Job(link: FakeNetdisk.link, password: nil, entries: entries, transferFolder: "/Ferry")
        job.accountKey = Fixture.account
        job.transferDirectory = TransferDirectory(reference: .baidu(path: job.remoteDirectory, fsID: 0), name: Job.shortID(job.id))
        job.transferProgress = TransferProgress(submitted: true, completed: true)
        // 服务端已经返回完成回执，但只落地 docs/a.bin。
        try await fixture.netdisk.transfer(FakeNetdisk.session, entries: [RemoteEntry(fsID: 1, name: "a.bin",
            path: "/share/docs/a.bin", isDirectory: false, size: 10, relativeDirectory: "docs")], to: job.remoteDirectory)
        try fixture.store.save([job])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error == TransferCheckError.incompleteTransfer("docs/b.bin").errorDescription)
        #expect(coordinator.job(job.id)?.files.isEmpty == true)
        #expect(fixture.netdisk.deletes.isEmpty)
        #expect(!fixture.netdisk.operations.contains(.list(job.remoteDirectory + "/unselected")))
    }

    @Test func completesWhenOnlyEmptyDirectoriesAreSelected() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)], emptyDirectories: ["empty", "nested/inner"])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let entries = fixture.netdisk.rootEntries().filter(\.isDirectory)
        #expect(entries.map(\.name) == ["empty", "nested"])
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: entries)
        try await coordinator.waitForPhase(.completed, of: job.id)
        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.isEmpty)
        #expect(finished.warning?.contains("没有文件") == true)
    }

    @Test func failsWhenListedFileIsOutsideJobDirectory() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.setNextListing([RemoteFile(path: "/elsewhere/a.bin", size: 10, fsID: 1)])

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("/elsewhere/a.bin") == true)
        #expect(coordinator.job(job.id)?.files.isEmpty == true)
    }

    @Test func failsOnUnsafeRelativePath() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: [])
        fixture.netdisk.setNextListing([
            RemoteFile(path: job.remoteDirectory + "/a.bin", size: 10, fsID: 1),
            RemoteFile(path: job.remoteDirectory + "/x/../../escape.bin", size: 10, fsID: 2),
        ])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("escape.bin") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "escape.bin").path))
    }

    @Test func renamesFilesThatCollideOnDisk() async throws {
        let share = ["Docs/a.txt": randomData(1_000), "docs/A.TXT": randomData(2_000)]
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        let files = try #require(coordinator.job(job.id)?.files)
        #expect(Set(files.map(\.relativePath)) == ["Docs/a.txt", "docs/A (1).TXT"])
        for file in files {
            let data = try #require(file.localURL.map { try Data(contentsOf: $0) })
            #expect(data == fixture.netdisk.data(at: file.remotePath))
        }
    }

    @Test func failsWithoutLogin() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        coordinator.netdisks[.baidu] = nil
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error == CoordinatorError.notLoggedIn.errorDescription)
    }

    // MARK: - 任务列表中无效的任务子目录

    /// 任务列表中的 `remoteDirectory` 可能被改成用户自己的目录。这些路径不是任务子目录，Ferry 不删除它们，也不转存到那里。
    private static let invalidJobDirectories = ["/", "/我的资料", ""]

    /// 从任务列表读出的分享任务，`remoteDirectory` 是给定的值（nil 时是 Ferry 写入的值）。
    private func savedShareJob(remoteDirectory: String?, phase: Job.Phase, fixture: Fixture) throws -> Job {
        var job = Job(link: FakeNetdisk.link, password: nil, entries: fixture.netdisk.rootEntries(), transferFolder: "/Ferry")
        job.phase = phase
        job.accountKey = Fixture.account
        job.transferProgress = TransferProgress(submitted: true, completed: true)
        if phase == .downloading {
            let url = fixture.downloads.appending(path: "a.bin")
            try Data().write(to: url)
            job.files = [JobFile(remotePath: job.remoteDirectory + "/a.bin", relativePath: "a.bin", size: 0, localURL: url)]
        }
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        if let remoteDirectory { object["remoteDirectory"] = remoteDirectory }
        return try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func retryAndRemoveDeleteOnlyValidJobDirectory() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let invalid = try Self.invalidJobDirectories.map {
            try savedShareJob(remoteDirectory: $0, phase: .failed(.transfer), fixture: fixture)
        }
        let valid = try savedShareJob(remoteDirectory: nil, phase: .failed(.transfer), fixture: fixture)
        try fixture.store.save(invalid + [valid])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        for job in invalid {
            await coordinator.retry(job.id)
            try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
            #expect(coordinator.job(job.id)?.error == TransferCheckError.missingJobDirectory.errorDescription)
            await coordinator.remove(job.id)
        }
        #expect(fixture.netdisk.operations.isEmpty)

        await coordinator.remove(valid.id)
        #expect(fixture.netdisk.deletes == [[valid.remoteDirectory]])
    }

    @Test func retryOfConfirmedTransferReusesDirectory() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        var job = try savedShareJob(remoteDirectory: nil, phase: .failed(.transfer), fixture: fixture)
        try await fixture.netdisk.transfer(FakeNetdisk.session, entries: fixture.netdisk.rootEntries(), to: job.remoteDirectory)
        job.transferDirectory = TransferDirectory(reference: .baidu(path: job.remoteDirectory, fsID: 0), name: Job.shortID(job.id))
        try fixture.store.save([job])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        // 已确认的转存重用目录，只在下载完成后清理一次。
        #expect(fixture.netdisk.deletes == [[job.remoteDirectory]])
    }

    @Test func cleanupDeletesOnlyValidJobDirectory() async throws {
        let fixture = Fixture()
        let invalid = try Self.invalidJobDirectories.map {
            try savedShareJob(remoteDirectory: $0, phase: .downloading, fixture: fixture)
        }
        let valid = try savedShareJob(remoteDirectory: nil, phase: .downloading, fixture: fixture)
        try fixture.store.save(invalid + [valid])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        for job in invalid + [valid] {
            try await coordinator.waitForPhase(.completed, of: job.id)
        }
        #expect(fixture.netdisk.deletes == [[valid.remoteDirectory]])
        #expect(coordinator.job(valid.id)?.isCleanedUp == true)
        #expect(invalid.allSatisfy { coordinator.job($0.id)?.isCleanedUp == false })
    }
}

/// 首文件取消后仍挂起，用于准确控制移除与另一文件完成的交错顺序。
private struct RemovalGateSource: DownloadSource {
    private struct State {
        var isOpen = false
        var entered = false
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    let base: FileServerSource
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(base: FileServerSource) { self.base = base }
    var hasEntered: Bool { state.withLock { $0.entered } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func open() {
        let waiter = state.withLock { value in
            value.isOpen = true
            defer { value.waiter = nil }
            return value.waiter
        }
        waiter?.resume()
    }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let context = try JSONDecoder().decode(DownloadContext.self, from: request.context)
        if context.reference.identifier.hasSuffix("/a-blocked.bin") {
            state.withLock { $0.entered = true }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let isOpen = state.withLock { value in
                        if !value.isOpen { value.waiter = continuation }
                        return value.isOpen
                    }
                    if isOpen { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.cancelled = true }
            }
        }
        return try await base.resolve(request)
    }
}
