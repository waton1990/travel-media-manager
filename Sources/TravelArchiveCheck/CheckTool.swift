import Foundation
import TravelArchiveCore

@main
struct CheckTool {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5, args[1] == "scan", let start = CaptureDay(args[3]), let end = CaptureDay(args[4]) else {
            print("只读扫描：TravelArchiveCheck scan <素材目录> <YYYY-MM-DD> <YYYY-MM-DD>")
            exit(2)
        }
        do {
            let request = ArchiveRequest(name: "只读核验", start: start, end: end, source: URL(fileURLWithPath: args[2]), destination: FileManager.default.temporaryDirectory)
            let report = try await MediaScanner.scan(request: request)
            let object: [String: Any] = [
                "readOnly": true,
                "range": [start.description, end.description],
                "fileCount": report.files.count,
                "totalBytes": report.totalBytes,
                "counts": Dictionary(uniqueKeysWithValues: MediaKind.allCases.map { ($0.rawValue, report.count($0)) }),
                "outsideRangeCount": report.outsideRangeCount,
                "ignoredCount": report.ignoredCount,
                "issues": report.issues.map { ["file": $0.url.lastPathComponent, "message": $0.message, "blocking": $0.isBlocking] as [String: Any] },
                "files": report.files.map { ["name": $0.url.lastPathComponent, "day": $0.captureDay.description, "kind": $0.kind.rawValue, "bytes": $0.size, "basis": $0.dateBasis] as [String: Any] }
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
