import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision

struct PhotoFitResult {
    let tuning: Tuning
    let predictedError: Double
    let baselineError: Double
    let warnings: [String]

    func blendedTuning(strength: Double) -> Tuning {
        let amount = strength.isFinite ? min(1, max(0, strength)) : 0
        func blend(_ target: Double) -> Double { 1 + (target - 1) * amount }
        return Tuning(brightness: blend(tuning.brightness), gamma: blend(tuning.gamma),
                      red: blend(tuning.red), green: blend(tuning.green), blue: blend(tuning.blue))
    }
}

struct PhotoCalibrationError: LocalizedError {
    let message: String
    let canReusePhoto: Bool

    init(message: String, canReusePhoto: Bool = false) {
        self.message = message
        self.canReusePhoto = canReusePhoto
    }

    var errorDescription: String? { message }
}

enum PhotoCalibration {
    static let levels = [0.15, 0.30, 0.45, 0.60, 0.75, 0.90]
    static let markerCenters = [CGPoint(x: 54, y: 54), CGPoint(x: 666, y: 54), CGPoint(x: 666, y: 466), CGPoint(x: 54, y: 466)]
    static let patchCenters = [CGPoint(x: 165, y: 195), CGPoint(x: 360, y: 195), CGPoint(x: 555, y: 195), CGPoint(x: 165, y: 335), CGPoint(x: 360, y: 335), CGPoint(x: 555, y: 335)]

    static func analyze(url: URL, session: String, allowPreviousSession: Bool = false) throws -> PhotoFitResult {
        guard session.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw error("촬영 세션을 확인하지 못했습니다. 비교 화면을 다시 열어 주세요.")
        }
        let image = try loadImage(url: url)
        let markers = try detectMarkers(image: image, session: session, allowPreviousSession: allowPreviousSession)
        let raster = try PhotoRaster(image: image)
        var measurements: [String: [[Double]?]] = [:]
        var warnings: [String] = []
        if allowPreviousSession {
            warnings.append("이전 촬영 사진을 사용했습니다. 촬영 이후 모니터 OSD 밝기·색상 설정과 주변 조명이 같아야 합니다.")
        }
        for role in ["R", "E"] {
            guard let corners = markers[role], corners.count == 4 else { throw error("두 화면의 QR 표시 8개가 모두 보이도록 다시 촬영해 주세요.") }
            let transform = try PhotoHomography(source: markerCenters, target: corners)
            try validateGeometry(corners: corners)
            measurements[role] = try patchCenters.map { center in
                let result = try samplePatch(center: center, transform: transform, raster: raster)
                if result == nil { warnings.append("반사광·노출 때문에 일부 회색 패치를 제외했습니다.") }
                return result
            }
        }
        guard let reference = measurements["R"], let external = measurements["E"] else { throw error("비교 화면을 찾지 못했습니다.") }
        let validIndices = levels.indices.filter { reference[$0] != nil && external[$0] != nil }
        guard validIndices.count >= 4, let first = validIndices.first, let last = validIndices.last,
              levels[first] <= 0.30, levels[last] >= 0.75 else {
            throw error("노출이 맞는 회색 패치가 부족합니다. 화면 반사를 피하고 카메라 노출을 조금 낮춰 두 화면을 함께 다시 촬영해 주세요.")
        }
        let fit = try fit(levels: validIndices.map { levels[$0] }, reference: validIndices.compactMap { reference[$0] }, external: validIndices.compactMap { external[$0] })
        return PhotoFitResult(tuning: fit.tuning, predictedError: fit.predictedError, baselineError: fit.baselineError,
                              warnings: Array(Set(warnings)).sorted() + fit.warnings)
    }

    static func fit(levels: [Double], reference: [[Double]], external: [[Double]]) throws -> PhotoFitResult {
        guard levels.count >= 4, levels.count == reference.count, levels.count == external.count,
              zip(levels, levels.dropFirst()).allSatisfy({ $0 < $1 }),
              levels.allSatisfy({ $0 > 0 && $0 < 1 }),
              (reference + external).allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
            throw error("색상 표본이 유효하지 않습니다. 비교 화면을 다시 촬영해 주세요.")
        }
        for samples in [reference, external] {
            for channel in 0..<3 {
                for index in 1..<samples.count where samples[index][channel] - samples[index - 1][channel] < 0.008 {
                    throw error("회색 단계의 밝기 순서가 불분명합니다. 자동 노출·HDR·반사광을 확인하고 다시 촬영해 주세요.")
                }
                guard samples.last![channel] - samples.first![channel] >= 0.20 else {
                    throw error("사진의 밝기 범위가 너무 좁습니다. 회색 단계가 분명히 보이도록 노출을 맞춰 주세요.")
                }
            }
        }
        let count = Double(levels.count * 3)
        let baselineMSE = zip(reference, external).reduce(0.0) { total, pair in
            total + zip(pair.0, pair.1).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
        } / count
        let baselineError = sqrt(baselineMSE)
        let note = "사진에서 추정한 상대 보정입니다. 오차는 사진 RGB 차이이며 실제 색 정확도나 ΔE, ICC 측정값이 아닙니다."
        if baselineError <= 0.008 {
            return PhotoFitResult(tuning: Tuning(), predictedError: baselineError, baselineError: baselineError,
                                  warnings: [note, "사진상 차이가 작아 원래 설정을 유지합니다."])
        }
        let curves = (0..<3).map { channel in PhotoResponseCurve(levels: levels, values: external.map { $0[channel] }) }
        let factors = (0...88).map { 0.56 + Double($0) * 0.005 }
        var bestScore = Double.infinity
        var bestMSE = baselineMSE
        var best = Tuning()
        for gammaStep in 0...70 {
            let gamma = 0.85 + Double(gammaStep) * 0.005
            let errors = (0..<3).map { channel in
                factors.map { factor in
                    levels.indices.reduce(0.0) { total, index in
                        let predicted = curves[channel].value(at: min(1, factor * pow(levels[index], 1 / gamma)))
                        return total + pow(predicted - reference[index][channel], 2)
                    }
                }
            }
            for brightnessStep in 0...40 {
                let brightness = 0.8 + Double(brightnessStep) * 0.005
                let permitted = factors.indices.filter { factors[$0] >= brightness * 0.7 - 1e-9 && factors[$0] <= brightness + 1e-9 }
                var gains: [Double] = []
                var sum = 0.0
                for channel in 0..<3 {
                    guard let index = permitted.min(by: { errors[channel][$0] < errors[channel][$1] }) else { continue }
                    gains.append(min(1, max(0.7, factors[index] / brightness)))
                    sum += errors[channel][index]
                }
                guard gains.count == 3 else { continue }
                let mse = sum / count
                let penalty = 0.00002 * (pow(gamma - 1, 2) + pow(brightness - 1, 2) + gains.reduce(0) { $0 + pow($1 - 1, 2) })
                if mse + penalty < bestScore {
                    bestScore = mse + penalty
                    bestMSE = mse
                    best = Tuning(brightness: brightness, gamma: gamma, red: gains[0], green: gains[1], blue: gains[2])
                }
            }
        }
        let predictedError = sqrt(bestMSE)
        guard predictedError <= 0.055, bestMSE < baselineMSE * 0.8 else {
            throw error("이 사진에서는 안전한 범위의 보정으로 차이를 줄일 수 없습니다. Mac 밝기를 낮추거나 외장 모니터의 밝기를 높인 뒤, 같은 노출로 다시 촬영해 주세요.")
        }
        let channelFactors = [best.red, best.green, best.blue].map { $0 * best.brightness }
        let normalizedBrightness = max(0.8, channelFactors.max() ?? 1)
        best = Tuning(brightness: normalizedBrightness, gamma: best.gamma,
                      red: channelFactors[0] / normalizedBrightness, green: channelFactors[1] / normalizedBrightness,
                      blue: channelFactors[2] / normalizedBrightness)
        var warnings = [note]
        if best.gamma <= 0.855 || best.gamma >= 1.195 || best.brightness <= 0.805 || min(best.red, best.green, best.blue) <= 0.705 {
            warnings.append("보정 한계에 가까운 값입니다. 모니터 자체 밝기·색온도를 먼저 조절하면 더 자연스러울 수 있습니다.")
        }
        if predictedError > 0.025 { warnings.append("사진에 남는 차이가 있습니다. 적용 후 두 화면을 눈으로 확인해 주세요.") }
        return PhotoFitResult(tuning: best, predictedError: predictedError, baselineError: baselineError, warnings: warnings)
    }

    static func loadImage(url: URL) throws -> CGImage {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 <= 80_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 120_000_000 else {
            throw error("사진을 읽을 수 없거나 파일이 너무 큽니다. 80MB 이하의 일반 사진을 선택해 주세요.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 4096,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width >= 600, image.height >= 300 else {
            throw error("사진 해상도가 너무 낮습니다. 두 화면이 크게 보이는 원본 사진을 선택해 주세요.")
        }
        return image
    }

    static func detectMarkers(image: CGImage, session: String, allowPreviousSession: Bool = false) throws -> [String: [CGPoint]] {
        var found: [String: [Int: CGPoint]] = [:]
        var sizes: [String: Double] = [:]
        var observations: [String: Int] = [:]
        var photoSession: String?
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        func scan(_ rect: CGRect) throws {
            guard let cropped = image.cropping(to: rect) else { throw error("사진 일부를 읽지 못했습니다.") }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            do { try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request]) }
            catch { throw self.error("QR 표시를 읽지 못했습니다. 화면 전체가 선명하게 나오도록 다시 촬영해 주세요.") }
            for observation in request.results ?? [] {
                guard let payload = observation.payloadStringValue, payload.hasPrefix("MC2|") else { continue }
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4, parts[1].range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                      ["R", "E"].contains(parts[2]), let corner = Int(parts[3]), (0...3).contains(corner) else {
                    throw error("QR 표시 형식이 올바르지 않습니다. 비교 화면을 다시 열어 주세요.")
                }
                guard photoSession == nil || photoSession == parts[1] else {
                    throw error("서로 다른 촬영 세션의 화면이 섞여 있습니다. 같은 촬영 세션의 두 화면이 담긴 사진을 선택해 주세요.")
                }
                photoSession = parts[1]
                func pixel(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: rect.minX + point.x * CGFloat(cropped.width), y: rect.minY + (1 - point.y) * CGFloat(cropped.height))
                }
                let corners = [pixel(observation.topLeft), pixel(observation.topRight), pixel(observation.bottomRight), pixel(observation.bottomLeft)]
                let area = polygonArea(corners)
                guard area >= 144 else { throw error("QR 표시가 너무 작습니다. 카메라를 가까이 가져가거나 화면을 크게 띄워 주세요.") }
                let center = try diagonalCenter(corners)
                let key = "\(parts[2])|\(corner)"
                if let existing = found[parts[2]]?[corner] {
                    let distance = hypot(existing.x - center.x, existing.y - center.y)
                    guard distance < 0.5 * min(sizes[key] ?? sqrt(area), sqrt(area)) else {
                        throw error("중복된 QR 표시가 보입니다. Mac 기준 화면과 외장 화면을 하나씩만 촬영해 주세요.")
                    }
                    let count = Double(observations[key] ?? 1)
                    found[parts[2], default: [:]][corner] = CGPoint(x: (existing.x * count + center.x) / (count + 1), y: (existing.y * count + center.y) / (count + 1))
                } else {
                    found[parts[2], default: [:]][corner] = center
                    sizes[key] = sqrt(area)
                }
                observations[key, default: 0] += 1
            }
        }
        try scan(imageBounds)
        if found["R"]?.count != 4 || found["E"]?.count != 4 {
            for y in [0.0, 0.3, 0.6] {
                for x in [0.0, 0.3, 0.6] {
                    let rect = CGRect(x: x * imageBounds.width, y: y * imageBounds.height,
                                      width: imageBounds.width * 0.4, height: imageBounds.height * 0.4).integral.intersection(imageBounds)
                    try scan(rect)
                }
            }
        }
        if let photoSession, photoSession != session, !allowPreviousSession {
            throw PhotoCalibrationError(message: "다른 촬영 세션의 사진입니다. 촬영 이후 화면 설정과 조명이 같다면 ‘이전 사진 재사용’을 선택하거나 현재 비교 화면을 다시 촬영해 주세요.", canReusePhoto: true)
        }
        guard found["R"]?.count == 4, found["E"]?.count == 4 else {
            throw error("QR 인식: Mac \(found["R"]?.count ?? 0)/4개 · 외장 모니터 \(found["E"]?.count ?? 0)/4개. 두 화면의 QR 표시 8개를 모두 찾지 못했습니다. 모서리가 가리지 않도록 두 화면을 한 사진에 크게 담아 주세요.")
        }
        return found.mapValues { entries in (0...3).compactMap { entries[$0] } }
    }

    private static func samplePatch(center: CGPoint, transform: PhotoHomography, raster: PhotoRaster) throws -> [Double]? {
        let left = try transform.project(CGPoint(x: center.x - 42, y: center.y))
        let right = try transform.project(CGPoint(x: center.x + 42, y: center.y))
        let top = try transform.project(CGPoint(x: center.x, y: center.y - 26))
        let bottom = try transform.project(CGPoint(x: center.x, y: center.y + 26))
        guard hypot(right.x - left.x, right.y - left.y) >= 12, hypot(bottom.x - top.x, bottom.y - top.y) >= 9 else {
            throw error("회색 패치가 너무 작습니다. 화면을 크게 띄우고 더 가까이 촬영해 주세요.")
        }
        var samples = [[Double]](repeating: [], count: 3)
        for y in -4...4 {
            for x in -4...4 {
                let point = try transform.project(CGPoint(x: center.x + Double(x) * 10.5, y: center.y + Double(y) * 6.5))
                let rgb = try raster.sample(point)
                for channel in 0..<3 { samples[channel].append(rgb[channel]) }
            }
        }
        var medians: [Double] = []
        for channel in samples {
            let sorted = channel.sorted()
            let median = sorted[sorted.count / 2]
            let spread = sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10]
            if median >= 0.985 || median <= 0.015 || spread > 0.10 || channel.filter({ $0 >= 0.995 }).count > channel.count / 10 { return nil }
            medians.append(median)
        }
        return medians
    }

    private static func validateGeometry(corners: [CGPoint]) throws {
        guard polygonArea(corners) >= 35_000 else { throw error("비교 화면이 사진에서 너무 작습니다. 두 화면을 더 크게 촬영해 주세요.") }
        let edges = corners.indices.map { index in hypot(corners[(index + 1) % 4].x - corners[index].x, corners[(index + 1) % 4].y - corners[index].y) }
        guard let shortest = edges.min(), let longest = edges.max(), shortest > 100, longest / shortest < 5 else {
            throw error("화면을 너무 비스듬하게 촬영했습니다. 두 화면 정면에 가깝게 다시 촬영해 주세요.")
        }
        let turns = corners.indices.map { index -> Double in
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { throw error("화면 모서리 배치를 확인하지 못했습니다. 비교 화면 전체가 보이도록 다시 촬영해 주세요.") }
    }

    private static func polygonArea(_ points: [CGPoint]) -> Double {
        abs(points.indices.reduce(0.0) { sum, index in
            let a = points[index], b = points[(index + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }

    private static func diagonalCenter(_ corners: [CGPoint]) throws -> CGPoint {
        let p = corners[0], q = corners[1]
        let r = CGPoint(x: corners[2].x - p.x, y: corners[2].y - p.y)
        let s = CGPoint(x: corners[3].x - q.x, y: corners[3].y - q.y)
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 0.0001 else { throw error("QR 표시 모양이 왜곡되었습니다. 정면에서 다시 촬영해 주세요.") }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / denominator
        return CGPoint(x: p.x + t * r.x, y: p.y + t * r.y)
    }

    static func error(_ message: String) -> PhotoCalibrationError { PhotoCalibrationError(message: message) }
}

private struct PhotoResponseCurve {
    let levels: [Double]
    let values: [Double]

    func value(at input: Double) -> Double {
        let index: Int
        if input <= levels[0] { index = 0 }
        else if input >= levels[levels.count - 1] { index = levels.count - 2 }
        else { index = max(0, (levels.firstIndex(where: { $0 >= input }) ?? 1) - 1) }
        let weight = (input - levels[index]) / (levels[index + 1] - levels[index])
        return min(1, max(0, values[index] + (values[index + 1] - values[index]) * weight))
    }
}

struct PhotoHomography {
    let coefficients: [Double]

    init(source: [CGPoint], target: [CGPoint]) throws {
        guard source.count == 4, target.count == 4 else { throw PhotoCalibration.error("화면 모서리 표본이 부족합니다.") }
        var matrix: [[Double]] = []
        for (sourcePoint, targetPoint) in zip(source, target) {
            let x = sourcePoint.x, y = sourcePoint.y, u = targetPoint.x, v = targetPoint.y
            matrix.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            matrix.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for column in 0..<8 {
            guard let pivot = (column..<8).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }), abs(matrix[pivot][column]) > 1e-9 else {
                throw PhotoCalibration.error("화면 원근을 계산하지 못했습니다. 두 화면이 평평하게 보이도록 다시 촬영해 주세요.")
            }
            matrix.swapAt(column, pivot)
            let divisor = matrix[column][column]
            for index in column...8 { matrix[column][index] /= divisor }
            for row in 0..<8 where row != column {
                let factor = matrix[row][column]
                for index in column...8 { matrix[row][index] -= factor * matrix[column][index] }
            }
        }
        coefficients = matrix.map { $0[8] }
    }

    func project(_ point: CGPoint) throws -> CGPoint {
        let h = coefficients
        let denominator = h[6] * point.x + h[7] * point.y + 1
        guard abs(denominator) > 1e-8 else { throw PhotoCalibration.error("화면 원근이 과도합니다. 정면에서 다시 촬영해 주세요.") }
        let x = (h[0] * point.x + h[1] * point.y + h[2]) / denominator
        let y = (h[3] * point.x + h[4] * point.y + h[5]) / denominator
        guard x.isFinite, y.isFinite else { throw PhotoCalibration.error("사진의 화면 위치를 계산하지 못했습니다.") }
        return CGPoint(x: x, y: y)
    }
}

struct PhotoRaster {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw PhotoCalibration.error("사진 색공간을 읽지 못했습니다.") }
        let rendered = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw PhotoCalibration.error("사진 픽셀을 읽지 못했습니다.") }
        bytes = buffer
    }

    func sample(_ point: CGPoint) throws -> [Double] {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 1, point.y >= 1, point.x < CGFloat(width - 1), point.y < CGFloat(height - 1) else {
            throw PhotoCalibration.error("회색 패치가 사진 밖에 있습니다. 화면 전체를 다시 촬영해 주세요.")
        }
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 1, y >= 1, x < width - 1, y < height - 1 else { throw PhotoCalibration.error("회색 패치가 사진 밖에 있습니다. 화면 전체를 다시 촬영해 주세요.") }
        var rgb = [Double](repeating: 0, count: 3)
        for dy in -1...1 {
            for dx in -1...1 {
                let index = ((y + dy) * width + x + dx) * 4
                guard bytes[index + 3] >= 250 else { throw PhotoCalibration.error("투명한 이미지 대신 촬영한 원본 사진을 사용해 주세요.") }
                for channel in 0..<3 { rgb[channel] += Double(bytes[index + channel]) / (255 * 9) }
            }
        }
        return rgb
    }
}
