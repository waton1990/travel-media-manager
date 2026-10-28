import Foundation
import TravelArchiveCore

@main
struct ModelChecks {
    @MainActor private static var passedChecks = 0

    @MainActor
    static func main() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("travel-model-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try checkFolderScopeLifetime(destination: destination)
        let model = makeSyntheticModel(destination: destination)
        await Task.yield()
        try expect(model.livePhotoImportMode == .complete, "Live Photos default to complete originals")
        try expect(model.canScan, "configured model can scan")
        model.phone.setDiscoveryActive(true)
        try expect(!model.canScan, "device discovery prevents concurrent scan")
        model.phone.setDiscoveryActive(false)
        model.scan()
        model.setFolder(destination.appendingPathComponent("not-selected"), isSource: false)
        model.setFolder(destination.appendingPathComponent("not-selected"), isSource: true)
        try expect(model.destinationURL == destination && model.sourceURL == nil,
                   "scanning retains selected folder access and rejects replacement")
        model.setLivePhotoImportMode(.stillOnly)
        try expect(model.livePhotoImportMode == .complete && !model.canChangeLivePhotoImportMode, "scanning freezes Live Photo mode")
        try await finish(model)
        try expect(model.phase == .ready && model.hasDeviceSelection, "scan reaches selection stage")
        try expect(model.matchedAssetCount == 4, "all four synthetic assets remain available")
        try expect(model.preview?.assetCount == 0 && model.preview?.fileCount == 0 && !model.canArchive, "default selection is empty and cannot archive")
        let beijing = model.locationGroups.first { $0.name.contains("北京") }!.id
        let tianjin = model.locationGroups.first { $0.name.contains("天津") }!.id
        model.selectLocation(beijing, selected: true)
        try expect(model.canArchive && model.preview?.assetCount == 1 && model.preview?.fileCount == 2, "Live Photo selects one asset and both files")
        try expect(model.preview?.count(.photo) == 1 && model.preview?.count(.video) == 0, "media counts represent assets")
        model.selectLocation(tianjin, selected: true)
        try expect(!model.canArchive && model.preview?.issues.contains(where: \.isBlocking) == true, "cross-city duplicate filename blocks import")
        model.selectLocation(tianjin, selected: false)
        try expect(model.canArchive && model.preview?.fileCount == 2, "deselection removes obsolete collision")
        model.selectUnknownAsset("unknown", selected: true)
        try expect(model.canArchive && model.preview?.assetCount == 2 && model.preview?.fileCount == 3, "unknown asset requires individual opt-in")
        try expect(model.preview?.totalBytes == 9_000_000, "complete plan counts both Live components and standalone video bytes")
        model.setLivePhotoImportMode(.stillOnly)
        try expect(model.canArchive && model.preview?.assetCount == 2 && model.preview?.fileCount == 2 && model.preview?.totalBytes == 6_000_000,
                   "still-only mode removes only Live companion from file and byte totals")
        try expect(model.preview?.count(.photo) == 1 && model.preview?.count(.video) == 1 && model.preview?.issues.isEmpty == true,
                   "still-only mode keeps standalone video and does not create omission warnings")
        try expect(model.selectedGroupIDs == [beijing] && model.selectedUnknownAssetIDs == ["unknown"] && model.matchedAssetCount == 4,
                   "mode change preserves cities, unknown choices, and full asset catalog")
        model.setLivePhotoImportMode(.complete)
        try expect(model.preview?.fileCount == 3 && model.preview?.totalBytes == 9_000_000 && model.phone.scanCount == 1,
                   "returning to complete restores companion without phone or geocoder rescan")
        model.selectLocation(beijing, selected: false)
        try expect(model.canArchive && model.preview?.assetCount == 1 && model.preview?.fileCount == 1, "reselection uses original full report")
        model.selectUnknownAsset("unavailable", selected: true)
        try expect(!model.canArchive && model.selectedAssetCount == 2 && model.preview?.assetCount == 1, "selected unavailable asset blocks without inflating archive counts")
        model.selectUnknownAsset("unavailable", selected: false)
        try expect(model.canArchive, "unselected unavailable asset no longer blocks")
        let occupiedTarget = model.targetURL!
        try FileManager.default.createDirectory(at: occupiedTarget, withIntermediateDirectories: false)
        model.selectLocation(beijing, selected: true)
        try expect(!model.canArchive && model.errorMessage != nil, "selection refresh revalidates destination")
        try FileManager.default.removeItem(at: occupiedTarget)
        model.selectLocation(beijing, selected: false)
        try expect(model.canArchive && model.errorMessage == nil, "corrected destination restores valid plan")
        model.selectLocation(beijing, selected: true)
        model.archive()
        model.setFolder(destination.appendingPathComponent("not-selected"), isSource: false)
        try expect(model.destinationURL == destination,
                   "archiving retains selected destination access and rejects replacement")
        model.setLivePhotoImportMode(.stillOnly)
        try expect(model.phase == .archiving && model.livePhotoImportMode == .complete && model.preview?.fileCount == 3 && model.preview?.totalBytes == 9_000_000,
                   "archiving freezes mode and preview for the captured complete plan")
        try await finish(model)
        try expect(model.phase == .failed && model.phone.finishAccessCount == 1, "import failure releases device access")
        try expect(Set(model.phone.preparedFileIDs) == ["beijing-still", "beijing-video", "unknown-video"] && model.phone.preparedLivePhotoImportMode == .complete,
                   "import preparation receives the selected complete plan snapshot")
        try expect(!FileManager.default.fileExists(atPath: occupiedTarget.path), "mock validation fails before target creation")
        model.endDate = model.endDate.addingTimeInterval(86_400)
        try expect(model.phase == .idle && model.preview == nil && !model.hasDeviceSelection && model.selectedGroupIDs.isEmpty && model.selectedUnknownAssetIDs.isEmpty, "editing dates clears full report and selection")
        model.scan()
        try await finish(model)
        model.selectLocation(beijing, selected: true)
        model.phone.selectedDeviceID = "different-synthetic-phone"
        await Task.yield()
        try expect(model.preview == nil && !model.hasDeviceSelection && model.selectedGroupIDs.isEmpty, "device change invalidates full selection")

        let stillModel = makeSyntheticModel(destination: destination)
        await Task.yield()
        stillModel.setLivePhotoImportMode(.stillOnly)
        stillModel.scan()
        try await finish(stillModel)
        stillModel.selectLocation(beijing, selected: true)
        stillModel.selectUnknownAsset("unknown", selected: true)
        try expect(stillModel.livePhotoImportMode == .stillOnly && stillModel.canArchive && stillModel.preview?.totalBytes == 6_000_000,
                   "mode selected before scanning applies to new place selections")
        stillModel.archive()
        stillModel.setLivePhotoImportMode(.complete)
        try expect(stillModel.livePhotoImportMode == .stillOnly && stillModel.preview?.fileCount == 2,
                   "still-only archive cannot switch to complete during import")
        try await finish(stillModel)
        try expect(Set(stillModel.phone.preparedFileIDs) == ["beijing-still", "unknown-video"] && stillModel.phone.preparedLivePhotoImportMode == .stillOnly,
                   "still-only preparation retains original photo and standalone video only")
        stillModel.endDate = stillModel.endDate.addingTimeInterval(86_400)
        try expect(stillModel.livePhotoImportMode == .stillOnly && stillModel.preview == nil,
                   "mode preference survives request changes during this app session")
        for cancelAfterCopy in [false, true] {
            let transfer = makeSyntheticModel(destination: destination)
            transfer.travelName = cancelAfterCopy ? "合成取消两阶段" : "合成完成两阶段"
            transfer.phone.enableSyntheticTransfer = true
            await Task.yield()
            transfer.scan()
            try await finish(transfer)
            transfer.selectUnknownAsset("unknown", selected: true)
            transfer.archive()
            let deadline = Date().addingTimeInterval(10)
            while (!transfer.phone.isWaitingForFinalValidation || transfer.archiveProgress?.stage != .verifying) && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(transfer.phone.isWaitingForFinalValidation && transfer.archiveProgress?.stage == .verifying,
                       "all source bytes reach the verification stage before import can complete")
            try expect(transfer.phase == .archiving && transfer.completedFiles == 0 && transfer.archiveProgress?.copiedFiles == 1 && transfer.result == nil,
                       "fully copied but unchecked data is visibly distinct from completed files")
            let target = transfer.targetURL!
            try expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("IMG_0003.MOV").path),
                       "uncertified data is not published under the original filename")
            if cancelAfterCopy { transfer.cancel() }
            else { transfer.phone.releaseFinalValidation = true }
            try await finish(transfer)
            if cancelAfterCopy {
                try expect(transfer.phase == .cancelled && transfer.completedFiles == 0 && transfer.result == nil,
                           "cancellation after transfer does not report unchecked data as successful")
                try expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty,
                           "cancelled unchecked temporary bytes are cleaned")
            } else {
                try expect(transfer.phase == .succeeded && transfer.completedFiles == 1 && transfer.result?.fileCount == 1,
                           "completed result appears only after local verification")
                let bytes = try Data(contentsOf: target.appendingPathComponent("IMG_0003.MOV"))
                try expect(bytes.count == 4_000_000 && bytes.allSatisfy { $0 == 42 },
                           "successful model import preserves the complete synthetic byte stream")
            }
            try expect(transfer.phone.validationCount == 2 && transfer.phone.finishAccessCount == 1,
                       "model uses bounded original checks and releases access after either outcome")
        }
        print("PASS: \(passedChecks) AppModel integration checks; local synthetic data only, no USB/network/media access.")
    }
    @MainActor
    static func checkFolderScopeLifetime(destination: URL) throws {
        var acquired = [URL]()
        var released = [URL]()
        var selection: SelectedFolderAccess? = SelectedFolderAccess(url: destination, startAccess: {
            acquired.append($0)
            return true
        }, stopAccess: { released.append($0) })
        try expect(selection != nil && acquired == [destination] && released.isEmpty,
                   "selected folder keeps an acquired security scope alive")
        let replacement = destination.appendingPathComponent("replacement")
        selection = SelectedFolderAccess(url: replacement, startAccess: {
            acquired.append($0)
            return true
        }, stopAccess: { released.append($0) })
        try expect(acquired == [destination, replacement] && released == [destination],
                   "replacing a folder releases its previous security scope")
        selection = nil
        try expect(released == [destination, replacement],
                   "ending folder selection balances every successful scope acquisition")
        selection = SelectedFolderAccess(url: destination, startAccess: { _ in false }, stopAccess: { released.append($0) })
        try expect(selection != nil, "folder selection also works when no explicit scope is acquired")
        selection = nil
        try expect(released == [destination, replacement],
                   "unacquired scopes never receive an unbalanced stop call")
    }
    @MainActor
    static func finish(_ model: AppModel) async throws {
        let limit = Date().addingTimeInterval(10)
        while model.isBusy && Date() < limit { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(!model.isBusy, "operation completed within test deadline")
    }
    @MainActor
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "AppModelCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        passedChecks += 1
        print("PASS: \(message)")
    }
}
