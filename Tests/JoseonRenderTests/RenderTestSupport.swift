import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

enum RenderTestSupport {
    /// Design review output. Set JOSEON_RENDER_OUT to choose the directory.
    static var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment["JOSEON_RENDER_OUT"]
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("joseon-render-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func requireMetal() throws {
        if RenderContext.shared == nil { throw XCTSkip("No Metal device") }
    }

    struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]   // RGBA
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        var alphaSum: Int {
            var s = 0
            for i in stride(from: 3, to: data.count, by: 4) { s += Int(data[i]) }
            return s
        }
        /// Distinct colors after dropping the two low bits per channel.
        var distinctColors: Int {
            var set = Set<UInt32>()
            for i in stride(from: 0, to: data.count, by: 4) {
                set.insert(UInt32(data[i] >> 2) << 16 | UInt32(data[i + 1] >> 2) << 8 | UInt32(data[i + 2] >> 2))
            }
            return set.count
        }
    }

    static func decode(_ cg: CGImage) -> Pixels {
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, data: data)
    }

    static func decode(png: Data) throws -> Pixels {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("PNG decode failed")
        }
        return decode(cg)
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func write(_ data: Data, _ name: String) {
        let url = outputDirectory.appendingPathComponent(name)
        try? data.write(to: url)
    }
}
