import Foundation
import TravelArchiveCore

/// These checks compile the production resolver with injected, in-memory lookup
/// and delay functions. No IPhoneSource, USBHelperClient, network, or media is used.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ScanProgress] = []

    func append(_ value: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        entries.append(value)
    }

    var values: [ScanProgress] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

private struct SyntheticLookupFailure: Error {}

@main
struct PlaceResolutionChecks {
    @MainActor private static var passedChecks = 0
    private static let day = CaptureDay("2026-10-13")!
    private static let first = GeoCoordinate(latitude: 35.3, longitude: 113.9)!
    private static let second = GeoCoordinate(latitude: 35.5, longitude: 112.8)!
    private static let third = GeoCoordinate(latitude: 35.7, longitude: 112.7)!
    private static let fourth = GeoCoordinate(latitude: 35.9, longitude: 112.6)!

    private static func asset(_ id: String, coordinate: GeoCoordinate? = first,
                              local: String? = nil, kind: MediaKind = .photo) -> DeviceTravelAsset {
        DeviceTravelAsset(id: id, name: "\(id).\(kind == .photo ? "HEIC" : "MOV")", kind: kind,
                          captureDay: day, coordinate: coordinate, fileIDs: [id], localPlaceName: local)
    }

    @MainActor
    static func main() async throws {
        try await allLocalSkipsLookupAndDelay()
        try await mixedSourcesPreserveProvenance()
        try await networkCacheAndLocalPrecedence()
        try await nearbyCoordinatesStaySeparate()
        try await missingAndBlankLocationsStayUnresolved()
        try await twoFailuresStillAllowLocalAndCachedResults()
        try await successResetsFailureBudget()
        try await unresolvedLookupCanBeRetried()
        try await cancellationBeforeResolution()
        try await cancellationFromLookup()
        try await cancellationFromPause()
        try await cancelledLookupDoesNotPopulateCache()
        print("PASS: \(passedChecks) production place-resolution checks; synthetic lookup/delay only, no USB/network/media access.")
    }

    @MainActor
    private static func allLocalSkipsLookupAndDelay() async throws {
        var calls = 0, pauses = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; throw SyntheticLookupFailure() },
                                         pause: { pauses += 1 })
        let assets = (0..<11).map { index in
            asset("local-\(index)", coordinate: GeoCoordinate(latitude: 35 + Double(index) / 1000, longitude: 113)!,
                  local: index < 8 ? "中国 · 示例甲省 · 示例甲市" : "中国 · 示例乙省 · 示例乙市",
                  kind: index < 7 ? .photo : .video)
        }
        let log = ProgressLog()
        let result = try await resolver.resolve(assets: assets, progress: { log.append($0) })
        try expect(calls == 0 && pauses == 0, "11 local cities make zero lookup and delay calls")
        try expect(result.names.count == 11 && result.localCount == 11 && result.cacheCount == 0 &&
                   result.networkRequestCount == 0 && result.unresolvedCount == 0,
                   "all-local statistics count every photo and video without network work")
        let cities = Dictionary(grouping: result.names.values, by: { $0 }).mapValues(\.count)
        try expect(cities == ["中国 · 示例甲省 · 示例甲市": 8, "中国 · 示例乙省 · 示例乙市": 3],
                   "all-local names preserve the two synthetic city groups")
        try expect(log.values.last?.visitedFiles == 11 && log.values.allSatisfy { (0...11).contains($0.visitedFiles) },
                   "all-local progress reaches the asset total without a network request")
        try expect(log.values.first?.currentFile.contains("手机现成") == true &&
                   log.values.last?.currentFile.contains("无需联网") == true &&
                   !log.values.contains { $0.currentFile.contains("正在联网") },
                   "all-local progress reports phone cities and never enters the network stage")
    }

    @MainActor
    private static func mixedSourcesPreserveProvenance() async throws {
        var calls: [GeoCoordinate] = [], pauses = 0
        let resolver = PlaceNameResolver(lookup: { coordinate in
            calls.append(coordinate)
            return coordinate == first ? "联网城市甲" : "联网城市乙"
        }, pause: { pauses += 1 })
        let assets = [asset("local-a", local: "手机城市甲"), asset("network-a"), asset("cached-a"),
                      asset("local-b", local: "手机城市乙"), asset("unknown", coordinate: nil),
                      asset("network-b", coordinate: second, kind: .video)]
        let log = ProgressLog()
        let result = try await resolver.resolve(assets: assets, progress: { log.append($0) })
        try expect(result.names == ["local-a": "手机城市甲", "network-a": "联网城市甲", "cached-a": "联网城市甲",
                                   "local-b": "手机城市乙", "network-b": "联网城市乙"],
                   "mixed resolution keeps local per-asset names separate from coordinate cache")
        try expect(calls == [first, second] && pauses == 1,
                   "only two distinct missing local cities trigger requests and one interval")
        try expect(result.localCount == 2 && result.cacheCount == 1 && result.networkRequestCount == 2 && result.unresolvedCount == 1,
                   "mixed source counters distinguish phone, cache, requests, and unknown")
        try expect(log.values.last?.visitedFiles == assets.count,
                   "mixed progress finishes after all local, cached, and unknown assets")
        let progress = log.values
        try expect(progress.first?.visitedFiles == 2 && progress.first?.currentFile.contains("手机现成") == true &&
                   progress.filter { $0.currentFile.contains("正在联网补查") }.count == 2 &&
                   progress.allSatisfy { (0...assets.count).contains($0.visitedFiles) } &&
                   zip(progress, progress.dropFirst()).allSatisfy { $0.visitedFiles <= $1.visitedFiles },
                   "mixed progress distinguishes ready phone cities from fallback without overflowing the total")
    }

    @MainActor
    private static func networkCacheAndLocalPrecedence() async throws {
        var calls = 0, pauses = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; return "联网原城市" }, pause: { pauses += 1 })
        _ = try await resolver.resolve(assets: [asset("initial")], progress: { _ in })
        let result = try await resolver.resolve(assets: [asset("edited-local", local: "手机更新城市"), asset("reused-network")], progress: { _ in })
        try expect(result.names["edited-local"] == "手机更新城市" && result.names["reused-network"] == "联网原城市",
                   "fresh phone city takes precedence while leaving network cache unchanged")
        try expect(calls == 1 && pauses == 0 && result.localCount == 1 && result.cacheCount == 1 && result.networkRequestCount == 0,
                   "repeated resolver use reuses only prior successful exact-coordinate lookups")
    }

    @MainActor
    private static func nearbyCoordinatesStaySeparate() async throws {
        var calls = 0
        let near = GeoCoordinate(latitude: first.latitude + 0.00000001, longitude: first.longitude)!
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; return calls == 1 ? "边界一侧" : "边界另一侧" }, pause: {})
        let result = try await resolver.resolve(assets: [asset("side-a"), asset("side-b", coordinate: near)], progress: { _ in })
        try expect(calls == 2 && result.names["side-a"] != result.names["side-b"] && result.cacheCount == 0,
                   "nearby but unequal coordinates are never merged across a possible city boundary")
    }

    @MainActor
    private static func missingAndBlankLocationsStayUnresolved() async throws {
        var calls = 0, pauses = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; return nil }, pause: { pauses += 1 })
        let result = try await resolver.resolve(assets: [asset("missing", coordinate: nil),
                                                       asset("stale-local", coordinate: nil, local: "无法确认的城市"),
                                                       asset("blank-local", local: " \t ")], progress: { _ in })
        try expect(result.names.isEmpty && result.localCount == 0 && result.unresolvedCount == 3,
                   "missing coordinates and blank local names do not produce trusted places")
        try expect(calls == 1 && pauses == 0 && result.networkRequestCount == 1,
                   "only a valid coordinate with no usable phone city attempts fallback")
        let groups = try DevicePlaceSelection.groups(assets: [asset("unknown", coordinate: nil)], resolvedPlaceNames: [:])
        try expect(groups.count == 1 && groups[0].isUnknown && groups[0].assets.count == 1,
                   "unresolved assets remain selectable in the existing unknown-location group")
    }

    @MainActor
    private static func twoFailuresStillAllowLocalAndCachedResults() async throws {
        var calls: [GeoCoordinate] = [], pauses = 0
        let resolver = PlaceNameResolver(lookup: { coordinate in
            calls.append(coordinate)
            if coordinate == first { return "已缓存城市" }
            throw SyntheticLookupFailure()
        }, pause: { pauses += 1 })
        _ = try await resolver.resolve(assets: [asset("seed-cache")], progress: { _ in })
        let log = ProgressLog()
        let result = try await resolver.resolve(assets: [asset("fail-a", coordinate: second),
                                                       asset("fail-b", coordinate: third), asset("cached-after-failure"),
                                                       asset("skip-network", coordinate: fourth),
                                                       asset("local-after-failure", coordinate: fourth, local: "手机有效城市")],
                                                progress: { log.append($0) })
        try expect(calls == [first, second, third] && pauses == 1 && result.networkRequestCount == 2,
                   "two failed fallback calls stop subsequent network work in that resolution")
        try expect(result.names == ["cached-after-failure": "已缓存城市", "local-after-failure": "手机有效城市"] &&
                   result.localCount == 1 && result.cacheCount == 1 && result.unresolvedCount == 3,
                   "fallback outage never suppresses later phone cities or successful cached results")
        try expect(log.values.last?.visitedFiles == 5,
                   "failed and skipped fallback items still advance final progress")
    }

    @MainActor
    private static func successResetsFailureBudget() async throws {
        var calls = 0, pauses = 0
        let resolver = PlaceNameResolver(lookup: { _ in
            calls += 1
            if calls.isMultiple(of: 2) { return "已解析城市\(calls)" }
            throw SyntheticLookupFailure()
        }, pause: { pauses += 1 })
        let assets = (0..<5).map { asset("alternating-\($0)", coordinate: GeoCoordinate(latitude: 20 + Double($0), longitude: 100)!) }
        let result = try await resolver.resolve(assets: assets, progress: { _ in })
        try expect(calls == 5 && pauses == 4 && result.networkRequestCount == 5 && result.names.count == 2 && result.unresolvedCount == 3,
                   "successful requests reset the consecutive-failure budget")
    }

    @MainActor
    private static func unresolvedLookupCanBeRetried() async throws {
        var calls = 0
        let resolver = PlaceNameResolver(lookup: { _ in
            calls += 1
            return calls == 1 ? nil : "后来查到的城市"
        }, pause: {})
        let firstResult = try await resolver.resolve(assets: [asset("first-try")], progress: { _ in })
        let secondResult = try await resolver.resolve(assets: [asset("second-try")], progress: { _ in })
        try expect(firstResult.names.isEmpty && firstResult.unresolvedCount == 1 &&
                   secondResult.names["second-try"] == "后来查到的城市" && calls == 2 && secondResult.cacheCount == 0,
                   "a missing lookup result is not cached as a permanent unknown")
    }

    @MainActor
    private static func cancellationBeforeResolution() async throws {
        var calls = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; return "不应查询" }, pause: {})
        let task = Task { @MainActor in
            try await resolver.resolve(assets: [asset("cancelled-local", local: "已知城市")], progress: { _ in })
        }
        task.cancel()
        do { _ = try await task.value; throw checkError("cancelled all-local resolution returned success") }
        catch is CancellationError { }
        try expect(calls == 0, "a task cancelled before all-local work stops without lookup")
    }

    @MainActor
    private static func cancellationFromLookup() async throws {
        var calls = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; throw CancellationError() }, pause: {})
        do {
            _ = try await resolver.resolve(assets: [asset("cancelled-network"), asset("later", coordinate: second)], progress: { _ in })
            throw checkError("lookup cancellation was converted to an unknown city")
        } catch is CancellationError { }
        try expect(calls == 1, "lookup cancellation propagates and stops later requests")
    }

    @MainActor
    private static func cancellationFromPause() async throws {
        var calls = 0, pauses = 0
        let resolver = PlaceNameResolver(lookup: { _ in calls += 1; return "首个城市" }, pause: {
            pauses += 1
            throw CancellationError()
        })
        do {
            _ = try await resolver.resolve(assets: [asset("first"), asset("second", coordinate: second)], progress: { _ in })
            throw checkError("pause cancellation was ignored")
        } catch is CancellationError { }
        try expect(calls == 1 && pauses == 1, "cancellation while waiting prevents the next network request")
    }

    @MainActor
    private static func cancelledLookupDoesNotPopulateCache() async throws {
        var calls = 0
        var continuation: CheckedContinuation<String?, Never>?
        let resolver = PlaceNameResolver(lookup: { _ in
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return "重新查询的城市"
        }, pause: {})
        let task = Task { @MainActor in
            try await resolver.resolve(assets: [asset("in-flight")], progress: { _ in })
        }
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil && Date() < deadline { await Task.yield() }
        guard let pending = continuation else {
            task.cancel()
            throw checkError("synthetic lookup did not reach its controlled suspension")
        }
        task.cancel()
        pending.resume(returning: "取消后才返回的城市")
        do { _ = try await task.value; throw checkError("cancelled lookup response was accepted") }
        catch is CancellationError { }
        let next = try await resolver.resolve(assets: [asset("next")], progress: { _ in })
        try expect(calls == 2 && next.networkRequestCount == 1 && next.cacheCount == 0 && next.names["next"] == "重新查询的城市",
                   "a response arriving after cancellation cannot populate the successful-result cache")
    }

    private static func checkError(_ message: String) -> NSError {
        NSError(domain: "PlaceResolutionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw checkError(message) }
        passedChecks += 1
        print("PASS: \(message)")
    }
}
