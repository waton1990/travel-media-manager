import Testing
import Foundation
import ImageIO
import AVFoundation
@testable import TravelArchiveCore

struct DeviceDateTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let quickTimeKey = AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue

    private func exif(_ original: Any) -> [String: Any] {
        [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: original]]
    }

    private func instant(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test func testIPhoneIMGNameDoesNotNeedOrSupplyDJIDate() {
        var metadata = exif("2026:08:26 16:02:18")
        metadata["filename"] = "IMG_0123.HEIC"
        let result = DeviceCaptureDateResolver.resolve(metadata: metadata, deviceDate: nil, timeZone: shanghai)
        #expect(result.day == CaptureDay("2026-08-26"))
        #expect(result.basis == "EXIF 原始拍摄日期")
        #expect(result.warning == nil)
        #expect(!result.hasConflict)

        let withoutDate = DeviceCaptureDateResolver.resolve(metadata: ["filename": "IMG_20260826.JPG"], deviceDate: nil, timeZone: shanghai)
        #expect(withoutDate.day == nil)
        #expect(!withoutDate.hasConflict)
    }

    @Test func testHEICExifNSDictionaryIsBridged() {
        let nested: NSDictionary = [kCGImagePropertyExifDateTimeOriginal as String: "2026:08:27 01:02:03" as NSString]
        let result = DeviceCaptureDateResolver.resolve(
            metadata: [kCGImagePropertyExifDictionary as String: nested, "UTI": "public.heic"],
            deviceDate: nil,
            timeZone: shanghai
        )
        #expect(result.day == CaptureDay("2026-08-27"))
        #expect(result.warning == nil)
    }

    @Test func testExifWrittenCalendarDayDoesNotShiftWithTripTimeZone() {
        let result = DeviceCaptureDateResolver.resolve(metadata: exif("2026:10:16 00:05:00"), deviceDate: nil, timeZone: losAngeles)
        #expect(result.day == CaptureDay("2026-10-16"))
        #expect(result.warning == nil)
    }

    @Test func testVideoZonedCreationPreservesWrittenDateAtMidnight() {
        let result = DeviceCaptureDateResolver.resolve(
            metadata: [quickTimeKey: "2026-10-16T00:05:00+0800"],
            deviceDate: nil,
            timeZone: losAngeles
        )
        #expect(result.day == CaptureDay("2026-10-16"))
        #expect(result.basis == "媒体拍摄日期（含时区）")
        #expect(result.warning == nil)
    }

    @Test func testQuickTimeIdentifierKeyIsRecognized() {
        let result = DeviceCaptureDateResolver.resolve(
            metadata: [AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue: "2026-08-28T23:55:00.123-12:00"],
            deviceDate: nil,
            timeZone: shanghai
        )
        #expect(result.day == CaptureDay("2026-08-28"))
        #expect(result.warning == nil)
    }

    @Test func testAgreeingReliableDatesRetainExifPriority() {
        var metadata = exif("2026:08:26 12:00:00")
        metadata[quickTimeKey] = "2026-08-26T12:00:00+08:00"
        let result = DeviceCaptureDateResolver.resolve(metadata: metadata, deviceDate: nil, timeZone: shanghai)
        #expect(result.day == CaptureDay("2026-08-26"))
        #expect(result.basis == "EXIF 原始拍摄日期")
        #expect(result.warning == nil)
    }

    @Test func testReliableMetadataConflictCannotBeOverriddenByDeviceFallback() throws {
        var metadata = exif("2026:08:26 23:59:59")
        metadata[quickTimeKey] = "2026-08-27T00:00:01+08:00"
        let deviceDate = try instant("2026-08-26T12:00:00Z")
        let result = DeviceCaptureDateResolver.resolve(metadata: metadata, deviceDate: deviceDate, timeZone: shanghai)
        #expect(result.day == nil)
        #expect(result.hasConflict)
        #expect(result.warning?.contains("冲突") == true)
        #expect(result.warning?.contains("2026-08-26") == true)
        #expect(result.warning?.contains("2026-08-27") == true)
    }

    @Test func testFlatAndNestedOriginalDatesAreCrossChecked() {
        var metadata = exif("2026:08:26 12:00:00")
        metadata[kCGImagePropertyExifDateTimeOriginal as String] = "2026:08:27 12:00:00"
        let result = DeviceCaptureDateResolver.resolve(metadata: metadata, deviceDate: nil, timeZone: shanghai)
        #expect(result.day == nil)
        #expect(result.hasConflict)
        #expect(result.warning?.contains("冲突") == true)
    }

    @Test func testInvalidExifCalendarDateAndTimeAreRejected() {
        for invalid in ["2026:02:29 12:00:00", "2026:02:30 12:00:00", "2026:08:26 24:00:00", "2026:08:26 12:60:00", "2026:08:26 12:00:60", "20260826120000"] {
            let result = DeviceCaptureDateResolver.resolve(metadata: exif(invalid), deviceDate: nil, timeZone: shanghai)
            #expect(result.day == nil)
            #expect(!result.hasConflict)
            #expect(result.warning?.contains("无效") == true)
        }
    }

    @Test func testDeviceFallbackUsesSelectedTripTimeZoneAcrossMidnight() throws {
        let deviceDate = try instant("2026-10-15T16:30:00Z")
        let east = DeviceCaptureDateResolver.resolve(metadata: nil, deviceDate: deviceDate, timeZone: shanghai)
        let west = DeviceCaptureDateResolver.resolve(metadata: nil, deviceDate: deviceDate, timeZone: losAngeles)
        #expect(east.day == CaptureDay("2026-10-16"))
        #expect(west.day == CaptureDay("2026-10-15"))
        #expect(east.basis.contains("设备报告日期"))
        #expect(east.basis.contains("Asia/Shanghai"))
        #expect(west.basis.contains("America/Los_Angeles"))
    }

    @Test func testDeviceFallbackRespectsDaylightSavingOffset() throws {
        let winter = DeviceCaptureDateResolver.resolve(metadata: nil, deviceDate: try instant("2026-01-16T07:30:00Z"), timeZone: losAngeles)
        let summer = DeviceCaptureDateResolver.resolve(metadata: nil, deviceDate: try instant("2026-07-16T07:30:00Z"), timeZone: losAngeles)
        #expect(winter.day == CaptureDay("2026-01-15"))
        #expect(summer.day == CaptureDay("2026-07-16"))
    }

    @Test func testInvalidMetadataCanFallbackButRetainsWarning() throws {
        let result = DeviceCaptureDateResolver.resolve(metadata: exif("2026:02:30 12:00:00"), deviceDate: try instant("2026-08-26T12:00:00Z"), timeZone: shanghai)
        #expect(result.day == CaptureDay("2026-08-26"))
        #expect(result.basis.contains("设备报告日期"))
        #expect(result.warning?.contains("无效") == true)
    }

    @Test func testReliableMetadataWinsOverDifferentLowerPriorityDeviceDate() throws {
        let result = DeviceCaptureDateResolver.resolve(metadata: exif("2026:08:26 12:00:00"), deviceDate: try instant("2026-10-16T12:00:00Z"), timeZone: shanghai)
        #expect(result.day == CaptureDay("2026-08-26"))
        #expect(result.basis == "EXIF 原始拍摄日期")
        #expect(result.warning == nil)
    }

    @Test func testNoUsableDateDoesNotUseFileDatesOrGenericCreationFields() throws {
        let date = try instant("2026-08-26T12:00:00Z")
        let result = DeviceCaptureDateResolver.resolve(metadata: [
            "fileCreationDate": date,
            "fileModificationDate": date,
            "modificationDate": date,
            "creationDate": date,
            "CreationDate": "2026-08-26T12:00:00Z",
            "{TIFF}": ["DateTime": "2026:08:26 12:00:00"],
            "{Exif}": ["DateTimeDigitized": "2026:08:26 12:00:00"]
        ], deviceDate: nil, timeZone: shanghai)
        #expect(result.day == nil)
        #expect(result.warning?.contains("没有可用") == true)
    }

    @Test func testVideoDatesWithoutExplicitTimeZoneOrValidTypeAreNotUsed() {
        for invalid: Any in ["2026-08-26T12:00:00", "2026-08-26T12:00:00+14:01", "2026-02-30T12:00:00+08:00", Date(), 12345] {
            let result = DeviceCaptureDateResolver.resolve(metadata: [quickTimeKey: invalid], deviceDate: nil, timeZone: shanghai)
            #expect(result.day == nil)
            #expect(result.warning != nil)
        }
    }

    @Test func testMalformedExifDoesNotHideValidVideoMetadata() {
        var metadata = exif("not a date")
        metadata[quickTimeKey] = "2026-08-26T12:00:00Z"
        let result = DeviceCaptureDateResolver.resolve(metadata: metadata, deviceDate: nil, timeZone: shanghai)
        #expect(result.day == CaptureDay("2026-08-26"))
        #expect(result.basis == "媒体拍摄日期（含时区）")
        #expect(result.warning?.contains("无效") == true)
    }

    @Test func testInvalidDeviceDateIsRejected() {
        for date in [Date.distantFuture, Date.distantPast, Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            let result = DeviceCaptureDateResolver.resolve(metadata: nil, deviceDate: date, timeZone: shanghai)
            #expect(result.day == nil)
            #expect(result.warning?.contains("设备报告日期无效") == true)
        }
    }
}
