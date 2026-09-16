import Foundation
import XCTest
@testable import XueniKit

final class SegmentsTests: XCTestCase {
    func testNormalizeMergesTouchingAndOverlapping() {
        let segs = Segments.normalize([Segment(200, 300), Segment(1, 100), Segment(101, 150), Segment(50, 60), Segment(10, 5)])
        XCTAssertEqual(segs, [Segment(1, 150), Segment(200, 300)])
        XCTAssertEqual(Segments.add(segs, 151, 199), [Segment(1, 300)])
    }

    func testQuestions() {
        let segs = [Segment(1, 100), Segment(200, 300)]
        XCTAssertEqual(Segments.segment(at: 50, in: segs), Segment(1, 100))
        XCTAssertNil(Segments.segment(at: 150, in: segs))
        XCTAssertEqual(Segments.topBelow(250, in: segs), 100)
        XCTAssertEqual(Segments.topBelow(150, in: segs), 100)
        XCTAssertNil(Segments.topBelow(1, in: segs))
        XCTAssertEqual(Segments.lowest(segs), 1)
        XCTAssertEqual(Segments.highest(segs), 300)
        XCTAssertEqual(Segments.blockCount(segs), 201)
        XCTAssertEqual(Segments.clipBelow(segs, 250), [Segment(250, 300)])
    }
}

final class ScanStoreTests: XCTestCase {
    @MainActor func testRowsAreFiledOnceAndFilledIn() async {
        let store = MemoryScanStore(chainId: 1)
        var events: [String] = []
        store.onEvent = { e in
            if case .rows(let rows) = e { events.append("rows \(rows.count)") }
        }
        let row = PostRow(chainId: 1, author: alice, index: 0, block: 10, prevBlock: 0, title: "a", txHash: "0x" + String(repeating: "1", count: 64))
        store.rememberPosts([row])
        var again = row
        again.ts = 123
        again.logIndex = 4
        let out = store.rememberPosts([again])
        XCTAssertEqual(out[0].ts, 123)
        XCTAssertEqual(out[0].logIndex, 4)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(events, ["rows 1", "rows 1"])
        XCTAssertEqual(store.rememberPosts([again]).count, 1)
        XCTAssertEqual(events.count, 2) // nothing new: no event
        XCTAssertEqual(store.knownPost(txHash: row.txHash)?.ts, 123)
        XCTAssertEqual(store.knownPost(author: alice, index: 0)?.block, 10)
    }

    @MainActor func testCoverageAndKnownChain() async {
        let store = MemoryScanStore(chainId: 1)
        let h = { (n: Int) in "0x" + String(format: "%064x", n) }
        store.rememberPosts([
            PostRow(chainId: 1, author: alice, index: 0, block: 10, prevBlock: 0, title: "first", txHash: h(1)),
            PostRow(chainId: 1, author: alice, index: 1, block: 20, prevBlock: 10, title: "second", txHash: h(2)),
            PostRow(chainId: 1, author: alice, index: 2, block: 30, prevBlock: 20, title: "third", txHash: h(3)),
            PostRow(chainId: 1, author: bob, index: 0, block: 25, prevBlock: 0, title: "bob", txHash: h(4)),
        ])
        store.rememberAuthorBlock(alice, 30)
        store.rememberAuthorBlock(alice, 20)
        XCTAssertEqual(store.knownChain(alice, from: 30).map { $0.index }, [2, 1])
        store.rememberFeedRange(5, 15)
        XCTAssertEqual(store.knownChain(alice, from: 30).map { $0.index }, [2, 1, 0])
        XCTAssertEqual(store.coveredPosts().map { $0.index }, [0])
        XCTAssertEqual(store.authorCoverage(alice), [Segment(5, 15), Segment(20, 20), Segment(30, 30)])
        XCTAssertEqual(store.authorPosts(bob, inBlock: 25).count, 1)
        XCTAssertEqual(store.allPosts().map { $0.block }, [30, 25, 20, 10])
        XCTAssertTrue(store.rememberBlockTime(25, ts: 99))
        XCTAssertEqual(store.knownBlockTime(25), 99)
        XCTAssertFalse(store.rememberBlockTime(25, ts: 100))
        XCTAssertEqual(store.authorScanEntries().map { $0.address }, [alice])
    }
}

final class ScannerTests: XCTestCase {
    @MainActor func testSweepReusesCoverageAndStopsAtTheFloor() async throws {
        let chain = FakeChain(chainId: 1, head: 1000)
        chain.publish(alice, at: 950, title: "a")
        chain.publish(bob, at: 300, title: "b")
        let store = MemoryScanStore(chainId: 1)
        store.rememberFeedRange(400, 600)
        var progress: [SweepProgress] = []
        let result = try await Scanner.sweepFeed(store: store, cursor: 1000, n: 20, floor: 100, windowSize: 200, maxBlocks: 100_000, fetchRange: { from, to in try await chain.postsInRange(from: from, to: to) }, onProgress: { progress.append($0) })
        XCTAssertEqual(result.rows.map { $0.title }, ["a", "b"])
        XCTAssertTrue(result.reachedFloor)
        XCTAssertEqual(chain.log, ["eth_getLogs 801-1000", "eth_getLogs 601-800", "eth_getLogs 200-399", "eth_getLogs 100-199"])
        XCTAssertEqual(result.fetched, 700)
        XCTAssertEqual(store.feedCoverage(), [Segment(100, 1000)])
        XCTAssertEqual(progress.filter { $0.phase == .fetched }.count, 4)
    }

    @MainActor func testSweepRespectsTheBudgetAndStopsWhenFull() async throws {
        let chain = FakeChain(chainId: 1, head: 1000)
        for b in stride(from: UInt64(990), through: 900, by: -10) { chain.publish(alice, at: b, title: "\(b)") }
        let store = MemoryScanStore(chainId: 1)
        let result = try await Scanner.sweepFeed(store: store, cursor: 1000, n: 3, floor: 0, windowSize: 50, maxBlocks: 120, fetchRange: { from, to in try await chain.postsInRange(from: from, to: to) })
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.map { $0.block }, [990, 980, 970])
        XCTAssertFalse(result.reachedFloor)
        let budgeted = try await Scanner.sweepFeed(store: store, cursor: 950, n: 100, floor: 0, windowSize: 50, maxBlocks: 120, fetchRange: { from, to in try await chain.postsInRange(from: from, to: to) })
        XCTAssertEqual(budgeted.fetched, 120)
        XCTAssertEqual(store.feedCoverage(), [Segment(831, 1000)], "the new windows join the range already read")
    }

    @MainActor func testWindowShrinksWhenTheNodeRefusesTheRange() async throws {
        let chain = FakeChain(chainId: 1, head: 1000)
        chain.rangeLimit = 60
        chain.publish(alice, at: 999, title: "a")
        let store = MemoryScanStore(chainId: 1)
        let result = try await Scanner.sweepFeed(store: store, cursor: 1000, n: 1, floor: 0, windowSize: 400, maxBlocks: 10_000, fetchRange: { from, to in try await chain.postsInRange(from: from, to: to) })
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(chain.log, ["eth_getLogs 601-1000", "eth_getLogs 801-1000", "eth_getLogs 901-1000", "eth_getLogs 951-1000"])
        XCTAssertEqual(store.feedCoverage(), [Segment(951, 1000)])
    }

    @MainActor func testAuthorRowsAndTheWalk() async throws {
        let chain = FakeChain(chainId: 1, head: 100)
        chain.publish(alice, at: 10, title: "first")
        chain.publish(alice, at: 20, title: "second")
        chain.publish(alice, at: 20, title: "third")
        chain.publish(alice, at: 30, title: "fourth")
        let store = MemoryScanStore(chainId: 1)
        let fetch: @MainActor (UInt64) async throws -> [PostRow] = { b in try await chain.authorPostsInBlock(author: alice, block: b) }
        let rows = try await Scanner.authorRows(store: store, author: alice, block: 20, fetchBlock: fetch)
        XCTAssertEqual(rows.map { $0.title }, ["third", "second"])
        _ = try await Scanner.authorRows(store: store, author: alice, block: 20, fetchBlock: fetch)
        XCTAssertEqual(chain.log.count, 1, "a covered block is never fetched twice")

        let found = try await Scanner.findAuthorPost(store: store, author: alice, targetIndex: 0, startBlock: 30, fetchBlock: fetch)
        XCTAssertEqual(found?.title, "first")
        let missing = try await Scanner.findAuthorPost(store: store, author: alice, targetIndex: 9, startBlock: 30, fetchBlock: fetch)
        XCTAssertNil(missing)

        chain.hideBlock = 40
        chain.publish(alice, at: 40, title: "fifth")
        do {
            _ = try await Scanner.authorRows(store: store, author: alice, block: 40, fetchBlock: fetch)
            XCTFail("a block the chain points at cannot be empty")
        } catch let error as ChainError {
            XCTAssertEqual(error, .nodeBehind(block: 40))
        }
        XCTAssertNil(Segments.segment(at: 40, in: store.authorCoverage(alice)), "nothing is claimed for a block that answered empty")
    }
}

final class TimelineTests: XCTestCase {
    func testEstimatesAreClampedBetweenExactTimes() {
        let h = { (n: Int) in "0x" + String(format: "%064x", n) }
        let rows = [
            PostRow(chainId: 1, author: alice, index: 3, block: 400, prevBlock: 300, title: "", txHash: h(4), ts: 4000),
            PostRow(chainId: 1, author: alice, index: 2, block: 300, prevBlock: 200, title: "", txHash: h(3), ts: nil),
            PostRow(chainId: 1, author: alice, index: 1, block: 200, prevBlock: 100, title: "", txHash: h(2), ts: 2500),
            PostRow(chainId: 1, author: alice, index: 0, block: 100, prevBlock: 0, title: "", txHash: h(1), ts: nil),
        ]
        let clock = ChainClock(block: 500, ts: 10_000, secondsPerBlock: 12)
        let timed = Timeline.timeRows(rows, clock: clock)
        XCTAssertEqual(timed.map { $0.exact }, [true, false, true, false])
        XCTAssertEqual(timed[1].ts, 4000, "an estimate cannot rise above the exact row before it")
        XCTAssertEqual(timed[3].ts, 2500, "an estimate above the exact row before it is pulled down to it")
        XCTAssertNil(Timeline.timeRows(rows, clock: nil)[1].ts)
    }

    func testMergedOrderAndFrontier() {
        let h = { (n: Int) in "0x" + String(format: "%064x", n) }
        let a = TimedRow(row: PostRow(chainId: 1, author: alice, index: 0, block: 10, prevBlock: 0, title: "", txHash: h(1)), ts: 100, exact: true)
        let b = TimedRow(row: PostRow(chainId: 167_000, author: alice, index: 0, block: 99, prevBlock: 0, title: "", txHash: h(2)), ts: 100, exact: true)
        let c = TimedRow(row: PostRow(chainId: 1, author: bob, index: 0, block: 5, prevBlock: 0, title: "", txHash: h(3)), ts: 50, exact: true)
        let none = TimedRow(row: PostRow(chainId: 1, author: bob, index: 1, block: 6, prevBlock: 5, title: "", txHash: h(4)), ts: nil, exact: false)
        let sorted = [none, c, b, a].sorted(by: Timeline.mergedBefore)
        XCTAssertEqual(sorted.map { $0.row.txHash }, [a, b, c, none].map { $0.row.txHash })

        let (tStar, leaders) = Timeline.frontier(of: [80, -.infinity, 80])
        XCTAssertEqual(tStar, 80)
        XCTAssertEqual(leaders, [0, 2])
        XCTAssertEqual(Timeline.frontier(of: [-.infinity]).leaders, [])
        XCTAssertEqual(Timeline.splitAtFrontier([a, b, c], 80), 1)
        XCTAssertEqual(Timeline.splitAtFrontier([a, b, c], 200), -1)
        XCTAssertEqual(Timeline.walkBound(hasMore: false, running: false, failed: false, everRefreshed: true, rows: [a]), -.infinity)
        XCTAssertEqual(Timeline.walkBound(hasMore: true, running: false, failed: false, everRefreshed: true, rows: [a, c]), 50)
        XCTAssertEqual(Timeline.walkBound(hasMore: false, running: false, failed: false, everRefreshed: false, rows: []), .infinity)
        XCTAssertEqual(Timeline.walkBound(hasMore: false, running: false, failed: false, everRefreshed: true, rows: []), -.infinity)
    }
}

final class ControllerTests: XCTestCase {
    @MainActor func testFeedRefreshThenExtendThenNothingNew() async {
        let chain = FakeChain(chainId: 1, head: 2000)
        chain.publish(alice, at: 1990, title: "newest")
        chain.publish(bob, at: 1200, title: "older")
        let store = MemoryScanStore(chainId: 1)
        let feed = FeedController(chainId: 1, store: store, io: chain, windowSize: 500, floor: 900, scanBlocks: 100_000, pageSize: 1, rescanDelay: { 60 })
        await feed.refresh()
        XCTAssertEqual(store.coveredPosts().map { $0.title }, ["newest"])
        XCTAssertEqual(feed.snapshot.head, 1999)
        XCTAssertEqual(feed.snapshot.coverage, [Segment(1500, 1999)])
        XCTAssertNil(feed.snapshot.error)
        let extended = await feed.extend()
        XCTAssertEqual(extended?.found, 1)
        XCTAssertEqual(extended?.reachedFloor, false)
        XCTAssertEqual(store.coveredPosts().map { $0.title }, ["newest", "older"])
        let before = chain.log.count
        feed.ensureFresh()
        await Task.yield()
        XCTAssertEqual(chain.log.count, before, "fresh enough: no request")
        let last = await feed.extend()
        XCTAssertEqual(last?.found, 0)
        XCTAssertEqual(last?.fetched, 100)
        XCTAssertEqual(last?.reachedFloor, true)
        XCTAssertTrue(feed.snapshot.exhausted)
        let atFloor = await feed.extend()
        XCTAssertEqual(atFloor?.reachedFloor, true)
        XCTAssertEqual(atFloor?.fetched, 0)
    }

    @MainActor func testFeedRecordsAFailure() async {
        let chain = FakeChain(chainId: 1, head: 2000)
        chain.rangeLimit = 10 // smaller than the minimum window: every fetch fails
        let store = MemoryScanStore(chainId: 1)
        let feed = FeedController(chainId: 1, store: store, io: chain, windowSize: 500, floor: 1000, scanBlocks: 100_000, pageSize: 1, rescanDelay: { 60 })
        await feed.refresh()
        XCTAssertNotNil(feed.snapshot.error)
        XCTAssertNil(feed.snapshot.job)
        XCTAssertNil(feed.snapshot.head, "a failed sweep records no head, so the next refresh starts over")
    }

    @MainActor func testAuthorListWalksRefreshesAndPages() async {
        let chain = FakeChain(chainId: 1, head: 100)
        for i in 0..<5 { chain.publish(alice, at: UInt64(10 + i * 10), title: "post \(i)") }
        let store = MemoryScanStore(chainId: 1)
        let list = AuthorListController(author: alice, store: store, io: chain, pageSize: 2, rescanDelay: { 60 })
        await list.refresh()
        XCTAssertEqual(list.snapshot.rows.map { $0.title }, ["post 4", "post 3"])
        XCTAssertTrue(list.snapshot.hasMore)
        XCTAssertEqual(store.authorScanHead(alice), 50)
        await list.loadMore()
        XCTAssertEqual(list.snapshot.rows.map { $0.title }, ["post 4", "post 3", "post 2", "post 1"])
        // A new post appears: a refresh walks from the new head down to the old one.
        chain.publish(alice, at: 70, title: "post 5")
        let reads = chain.log.count
        await list.refresh()
        XCTAssertEqual(list.snapshot.rows.map { $0.title }, ["post 5", "post 4", "post 3", "post 2", "post 1"])
        XCTAssertEqual(chain.log.count - reads, 2, "one head read, one block read: nothing already read is asked again")
        await list.loadMore()
        XCTAssertFalse(list.snapshot.hasMore)
        // A second controller over the same store starts with the walk it left.
        let again = AuthorListController(author: alice, store: store, io: chain, pageSize: 2, rescanDelay: { 60 })
        XCTAssertEqual(again.snapshot.rows.count, 6)
    }

    @MainActor func testAuthorListNeverPublished() async {
        let chain = FakeChain(chainId: 1, head: 100)
        let store = MemoryScanStore(chainId: 1)
        let list = AuthorListController(author: bob, store: store, io: chain, pageSize: 2, rescanDelay: { 60 })
        await list.refresh()
        XCTAssertEqual(list.snapshot.rows.count, 0)
        XCTAssertNotNil(list.snapshot.refreshedAt)
        XCTAssertNil(list.snapshot.error)
    }

    @MainActor func testMergedFeedOrdersAcrossChainsAndMarksTheFrontier() async {
        let eth = FakeChain(chainId: 1, head: 2000)
        eth.secondsPerBlock = 12
        let taiko = FakeChain(chainId: 167_000, head: 5000)
        taiko.secondsPerBlock = 2
        taiko.genesisTs = eth.genesisTs
        eth.publish(alice, at: 1990, title: "eth")
        taiko.publish(bob, at: 4990, title: "taiko")
        let ethStore = MemoryScanStore(chainId: 1)
        let taikoStore = MemoryScanStore(chainId: 167_000)
        // A budget of 1,000 blocks per scan: each chain's first sweep stops
        // well above its floor, so the merge has a frontier to mark.
        let ethFeed = FeedController(chainId: 1, store: ethStore, io: eth, windowSize: 1000, floor: 0, scanBlocks: 1000, pageSize: 20, rescanDelay: { 60 })
        let taikoFeed = FeedController(chainId: 167_000, store: taikoStore, io: taiko, windowSize: 1000, floor: 0, scanBlocks: 1000, pageSize: 20, rescanDelay: { 60 })
        let merged = MergedFeed(chains: [(eth.source(store: ethStore), ethFeed, 0), (taiko.source(store: taikoStore), taikoFeed, 0)], pageSize: 20)
        await merged.refresh()
        await eventually { merged.snapshot.rows.count == 2 && merged.snapshot.frontier?.leaders.first?.exact == true }
        let snap = merged.snapshot
        XCTAssertEqual(snap.rows.map { $0.row.title }, ["eth", "taiko"], "ordered by time, not by block height")
        XCTAssertEqual(snap.chains.map { $0.chainId }, [1, 167_000])
        XCTAssertEqual(snap.chains.map { $0.coverage }, [[Segment(1000, 1999)], [Segment(4000, 4999)]])
        // Ethereum's coverage bottom (block 1000, +12,000 s) is later in time
        // than Taiko's (block 4000, +8,000 s): Ethereum is the least-read chain.
        XCTAssertEqual(snap.frontier?.leaders.map { $0.chainId }, [1])
        XCTAssertEqual(snap.frontier?.after, 0, "the Taiko row sits below the frontier")
        XCTAssertFalse(snap.done)
        await merged.loadMore()
        await eventually { merged.snapshot.chains[0].exhausted }
        XCTAssertTrue(merged.snapshot.chains[0].exhausted, "load more deepened the chain at the frontier")
        XCTAssertEqual(merged.snapshot.frontier?.leaders.map { $0.chainId }, [167_000])
    }

    @MainActor func testMergedWalksOverTwoAuthors() async {
        let chain = FakeChain(chainId: 1, head: 1000)
        chain.publish(alice, at: 100, title: "alice 1")
        chain.publish(bob, at: 200, title: "bob 1")
        chain.publish(alice, at: 300, title: "alice 2")
        let store = MemoryScanStore(chainId: 1)
        let walks = [alice, bob].map { author in
            WalkSource(source: chain.source(store: store), author: author, list: AuthorListController(author: author, store: store, io: chain, pageSize: 1, rescanDelay: { 60 }))
        }
        let merged = MergedWalks(walks: walks, pageSize: 2)
        await merged.refresh()
        await eventually { merged.snapshot.rows.count == 2 }
        XCTAssertEqual(merged.snapshot.rows.map { $0.row.title }, ["alice 2", "bob 1"])
        XCTAssertTrue(merged.snapshot.hasMore)
        await merged.loadMore()
        await eventually { merged.snapshot.rows.count == 3 }
        XCTAssertEqual(merged.snapshot.rows.map { $0.row.title }, ["alice 2", "bob 1", "alice 1"])
        XCTAssertEqual(merged.snapshot.silent, [])
        XCTAssertTrue(chain.log.allSatisfy { !$0.hasPrefix("eth_getLogs") || $0.split(separator: " ")[1].contains("-") == false }, "a followed author never costs a range scan")
    }
}
