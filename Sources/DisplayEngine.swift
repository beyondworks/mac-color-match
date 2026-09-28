import Foundation
import AppKit
import CoreGraphics

struct Tuning: Codable, Equatable {
    var brightness: Double = 1
    var gamma: Double = 1
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1

    var isValid: Bool {
        (0.65...1).contains(brightness) && (0.7...1.4).contains(gamma)
            && [red, green, blue].allSatisfy { (0.7...1).contains($0) }
    }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let stableID: String
    let name: String
    let builtIn: Bool
    let width: Int
    let height: Int
}

struct GammaTable: Codable, Equatable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    var count: Int { red.count }
    var isValid: Bool {
        count >= 2 && count <= 65_536 && green.count == count && blue.count == count
            && [red, green, blue].allSatisfy { channel in
                channel.allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
    }

    func corrected(_ tuning: Tuning) -> GammaTable {
        func map(_ values: [Float], gain: Double) -> [Float] {
            // Compose with the original profile LUT, never a previously corrected LUT.
            values.indices.map { index in
                let x = pow(Double(index) / Double(values.count - 1), 1 / tuning.gamma)
                return Float(Double(Self.sample(values, at: x)) * gain * tuning.brightness)
            }
        }
        return GammaTable(red: map(red, gain: tuning.red), green: map(green, gain: tuning.green), blue: map(blue, gain: tuning.blue))
    }

    static func sample(_ values: [Float], at position: Double) -> Float {
        let x = min(1, max(0, position)) * Double(values.count - 1)
        let lower = Int(x)
        let upper = min(lower + 1, values.count - 1)
        return values[lower] + (values[upper] - values[lower]) * Float(x - Double(lower))
    }

    func maximumDifference(from other: GammaTable) -> Float {
        guard isValid, other.isValid else { return .infinity }
        let samples = max(count, other.count)
        var result: Float = 0
        for (left, right) in zip([red, green, blue], [other.red, other.green, other.blue]) {
            for index in 0..<samples {
                let position = Double(index) / Double(samples - 1)
                result = max(result, abs(Self.sample(left, at: position) - Self.sample(right, at: position)))
            }
        }
        return result
    }
}

private struct RecoveryRecord: Codable {
    let stableID: String
    let original: GammaTable
    var expected: GammaTable
}

private struct DisplaySession {
    let stableID: String
    let original: GammaTable
    var expected: GammaTable
}

struct DisplayEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class GammaEngine {
    // Allow 8-bit LUT quantization, but do not claim physical color accuracy.
    static let readbackTolerance: Float = 0.005
    private var sessions: [CGDirectDisplayID: DisplaySession] = [:]
    private let recoveryURL: URL

    init(recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacColorMatch/recovery.json")
    }

    func enumerate() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let stableID = identity(id) else { return nil }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return DisplayInfo(id: id, stableID: stableID, name: screen?.localizedName ?? "외장 디스플레이 \(id)",
                               builtIn: CGDisplayIsBuiltin(id) != 0, width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }.sorted { $0.builtIn && !$1.builtIn }
    }

    func begin(displayID: CGDirectDisplayID) throws {
        let stableID = try validate(displayID)
        if let session = sessions[displayID] {
            guard session.stableID == stableID else {
                throw failure("모니터 연결이 변경되었습니다. 앱을 다시 열어 디스플레이를 선택해 주세요.")
            }
            return
        }
        var records = try loadRecords()
        if let record = records[stableID] {
            guard record.original.isValid, record.expected.isValid, record.stableID == stableID else {
                throw failure("원복 백업이 손상되었습니다. recovery.json을 보존한 뒤 지원을 요청해 주세요.")
            }
            let current = try readback(displayID: displayID)
            if !matches(current, record.original) {
                guard matches(current, record.expected) else { throw externalChange() }
                try writeAndVerify(record.original, displayID: displayID, stableID: stableID)
            }
            records.removeValue(forKey: stableID)
            try saveRecords(records)
        }
        let original = try readback(displayID: displayID)
        sessions[displayID] = DisplaySession(stableID: stableID, original: original, expected: original)
    }

    func apply(_ tuning: Tuning, to displayID: CGDirectDisplayID) throws {
        guard tuning.isValid else { throw failure("보정 값이 허용 범위를 벗어났습니다.") }
        try begin(displayID: displayID)
        guard var session = sessions[displayID] else { throw failure("모니터 보정을 시작하지 못했습니다.") }
        _ = try validate(displayID, expected: session.stableID)
        let current = try readback(displayID: displayID)
        guard matches(current, session.expected) else { throw externalChange() }
        let desired = session.original.corrected(tuning)
        var records = try loadRecords()
        records[session.stableID] = RecoveryRecord(stableID: session.stableID, original: session.original, expected: desired)
        try saveRecords(records)
        do {
            try writeAndVerify(desired, displayID: displayID, stableID: session.stableID)
            session.expected = desired
            sessions[displayID] = session
        } catch {
            let applyError = error.localizedDescription
            do {
                try writeAndVerify(current, displayID: displayID, stableID: session.stableID)
                records[session.stableID] = RecoveryRecord(stableID: session.stableID, original: session.original, expected: current)
                try saveRecords(records)
            } catch {
                throw failure("\(applyError) 이전 상태 복구도 확인하지 못했습니다: \(error.localizedDescription). 디스플레이 설정의 색상 프로파일을 다시 선택해 주세요.")
            }
            throw failure("\(applyError) 적용 전 상태로 되돌렸습니다.")
        }
    }

    func restore(displayID: CGDirectDisplayID) throws {
        guard let session = sessions[displayID] else { return }
        _ = try validate(displayID, expected: session.stableID)
        let current = try readback(displayID: displayID)
        if !matches(current, session.original) {
            guard matches(current, session.expected) else { throw externalChange() }
            try writeAndVerify(session.original, displayID: displayID, stableID: session.stableID)
        }
        var records = try loadRecords()
        records.removeValue(forKey: session.stableID)
        try saveRecords(records)
        sessions.removeValue(forKey: displayID)
    }

    func restoreAll() -> [String] {
        var errors: [String] = []
        for id in Array(sessions.keys) {
            do { try restore(displayID: id) }
            catch { errors.append("디스플레이 \(id): \(error.localizedDescription)") }
        }
        return errors
    }

    func adoptCurrentBaseline(displayID: CGDirectDisplayID) throws {
        let stableID = try validate(displayID)
        let current = try readback(displayID: displayID)
        var records = try loadRecords()
        if let record = records[stableID] {
            let archiveURL = recoveryURL.deletingLastPathComponent()
                .appendingPathComponent("recovery-archive-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            do {
                try JSONEncoder().encode(record).write(to: archiveURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            } catch { throw failure("이전 원복 백업을 보존하지 못해 기준 변경을 중단했습니다: \(error.localizedDescription)") }
            records.removeValue(forKey: stableID)
            try saveRecords(records)
        }
        sessions[displayID] = DisplaySession(stableID: stableID, original: current, expected: current)
    }

    func readback(displayID: CGDirectDisplayID) throws -> GammaTable {
        guard CGDisplayIsOnline(displayID) != 0 else { throw failure("모니터 연결이 끊어졌습니다. 다시 연결해 주세요.") }
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity >= 2, capacity <= 65_536 else { throw failure("이 디스플레이 또는 연결 방식은 감마 테이블을 지원하지 않습니다.") }
        var red = [Float](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count)
        guard result == .success, count >= 2, count <= capacity else {
            throw failure("현재 색상 설정을 읽지 못했습니다 (CoreGraphics \(result.rawValue)). HDR을 끄고 다시 시도해 주세요.")
        }
        let table = GammaTable(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
        guard table.isValid else { throw failure("디스플레이에서 유효하지 않은 감마 테이블을 반환했습니다. 보정을 중단합니다.") }
        return table
    }

    private func identity(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    private func validate(_ id: CGDirectDisplayID, expected: String? = nil) throws -> String {
        guard CGDisplayIsOnline(id) != 0, let stableID = identity(id) else {
            throw failure("모니터 연결이 끊어졌습니다. 다시 연결해 주세요. 원복 백업은 보존됩니다.")
        }
        guard expected == nil || expected == stableID else { throw failure("디스플레이 ID가 다른 모니터에 할당되어 보정을 중단했습니다.") }
        guard CGDisplayIsBuiltin(id) == 0 else { throw failure("기준 화면인 Mac 내장 디스플레이는 보정하지 않습니다.") }
        guard CGDisplayIsInMirrorSet(id) == 0 else { throw failure("화면 미러링을 끈 뒤 확장 디스플레이로 사용해 주세요.") }
        return stableID
    }

    private func writeAndVerify(_ table: GammaTable, displayID: CGDirectDisplayID, stableID: String) throws {
        _ = try validate(displayID, expected: stableID)
        guard table.isValid else { throw failure("유효하지 않은 감마 보정 값을 차단했습니다.") }
        let result = CGSetDisplayTransferByTable(displayID, UInt32(table.count), table.red, table.green, table.blue)
        guard result == .success else { throw failure("색상 적용에 실패했습니다 (CoreGraphics \(result.rawValue)).") }
        _ = try validate(displayID, expected: stableID)
        let observed = try readback(displayID: displayID)
        guard matches(observed, table) else {
            throw failure("macOS가 요청한 보정을 반영하지 않았습니다. HDR·Night Shift·다른 색상 보정 앱을 끄고 다시 시도해 주세요")
        }
    }

    private func matches(_ a: GammaTable, _ b: GammaTable) -> Bool {
        a.maximumDifference(from: b) <= Self.readbackTolerance
    }

    private func loadRecords() throws -> [String: RecoveryRecord] {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return [:] }
        do { return try JSONDecoder().decode([String: RecoveryRecord].self, from: Data(contentsOf: recoveryURL)) }
        catch { throw failure("원복 백업을 읽지 못했습니다. 파일을 보존한 채 확인해 주세요: \(recoveryURL.path)") }
    }

    private func saveRecords(_ records: [String: RecoveryRecord]) throws {
        do {
            let directory = recoveryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(records)
            try data.write(to: recoveryURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        } catch { throw failure("원복 백업을 저장하지 못해 보정을 중단했습니다: \(error.localizedDescription)") }
    }

    private func externalChange() -> DisplayEngineError {
        failure("다른 앱 또는 macOS가 색상 설정을 변경했습니다. 해당 설정을 덮어쓰지 않았습니다. 현재 화면을 기준으로 다시 시작하려면 ‘현재 상태를 새 기준으로’ 버튼을 눌러 주세요. 이전 원복 백업은 별도 파일로 보존됩니다.")
    }

    private func failure(_ message: String) -> DisplayEngineError { DisplayEngineError(message: message) }
}
