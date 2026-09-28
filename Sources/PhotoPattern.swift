import AppKit
import CoreImage

enum PhotoPattern {
    enum PatternError: LocalizedError {
        case invalidIdentity
        case renderingFailed

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "촬영 세션 또는 화면 식별자가 올바르지 않습니다."
            case .renderingFailed: return "사진 보정 패턴을 만들지 못했습니다."
            }
        }
    }

    static func image(session: String, role: String) throws -> NSImage {
        guard ["R", "E"].contains(role), !session.isEmpty,
              session.utf8.count <= 64,
              session.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else { throw PatternError.invalidIdentity }

        let width = 720.0
        let height = 520.0
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1440, height: 1040,
                                      bitsPerComponent: 8, bytesPerRow: 1440 * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PatternError.renderingFailed }

        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray(0.10, space: space))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let corners: [CGPoint] = [CGPoint(x: 54, y: 54), CGPoint(x: 666, y: 54),
                                   CGPoint(x: 666, y: 466), CGPoint(x: 54, y: 466)]
        let ciContext = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        for (index, center) in corners.enumerated() {
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
                throw PatternError.renderingFailed
            }
            filter.setValue(Data("MC2|\(session)|\(role)|\(index)".utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage,
                  let code = ciContext.createCGImage(output, from: output.extent) else {
                throw PatternError.renderingFailed
            }
            let modules = code.width
            let pixelsPerModule = max(1, 176 / (modules + 8))
            let side = CGFloat(modules * pixelsPerModule) / 2
            let frame = CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88)
            context.setFillColor(gray(1, space: space))
            context.fill(frame)
            context.saveGState()
            context.interpolationQuality = .none
            context.translateBy(x: center.x - side / 2, y: center.y + side / 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(code, in: CGRect(x: 0, y: 0, width: side, height: side))
            context.restoreGState()
        }

        let centers: [CGPoint] = [CGPoint(x: 165, y: 195), CGPoint(x: 360, y: 195),
                                   CGPoint(x: 555, y: 195), CGPoint(x: 165, y: 335),
                                   CGPoint(x: 360, y: 335), CGPoint(x: 555, y: 335)]
        let levels: [CGFloat] = [0.15, 0.30, 0.45, 0.60, 0.75, 0.90]
        for (center, level) in zip(centers, levels) {
            context.setFillColor(gray(level, space: space))
            context.fill(CGRect(x: center.x - 75, y: center.y - 52.5, width: 150, height: 105))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawText(role == "R" ? "Mac 기준" : "외장 모니터",
                 in: CGRect(x: 112, y: 27, width: 496, height: 32),
                 size: 25, weight: .semibold, white: 0.97)
        drawText("두 화면의 표식을 모두 담아 한 장으로 촬영",
                 in: CGRect(x: 106, y: 67, width: 508, height: 25),
                 size: 16, weight: .regular, white: 0.78)
        for (index, center) in centers.enumerated() {
            drawText("\(Int((levels[index] * 100).rounded()))% 회색",
                     in: CGRect(x: center.x - 75, y: center.y + 57, width: 150, height: 22),
                     size: 13, weight: .medium, white: 0.74)
        }
        drawText("표식과 회색 칸이 가리지 않도록 촬영하세요",
                 in: CGRect(x: 108, y: 437, width: 504, height: 23),
                 size: 15, weight: .regular, white: 0.82)
        drawText("촬영 세션 · \(session)",
                 in: CGRect(x: 107, y: 471, width: 506, height: 25),
                 size: 11, weight: .regular, white: 0.60)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { throw PatternError.renderingFailed }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func gray(_ level: CGFloat, space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [level, level, level, 1])!
    }

    private static func drawText(_ text: String, in rect: CGRect, size: CGFloat,
                                 weight: NSFont.Weight, white: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(srgbRed: white, green: white, blue: white, alpha: 1),
            .paragraphStyle: paragraph
        ])
    }
}
