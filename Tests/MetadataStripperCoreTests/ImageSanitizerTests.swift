import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MetadataStripperCore

final class ImageSanitizerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-stripper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testJPEGRemovesPrivateMetadataPreservesOrientationAndOriginal() throws {
        let sourceDirectory = try makeDirectory(named: "source")
        let outputDirectory = try makeDirectory(named: "output")
        let sourceURL = sourceDirectory.appendingPathComponent("portrait.jpg")
        try makeTaggedFixture(typeIdentifier: "public.jpeg", at: sourceURL, orientation: 6)

        let originalData = try Data(contentsOf: sourceURL)
        XCTAssertTrue(try metadataDescription(at: sourceURL).contains("SECRET_"))

        let result = try ImageSanitizer.stripMetadata(from: sourceURL, into: outputDirectory)

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        XCTAssertFalse(try metadataDescription(at: result.outputURL).contains("SECRET_"))
        XCTAssertEqual(try orientation(at: result.outputURL), 6)
        XCTAssertEqual(try dimensions(at: result.outputURL), CGSize(width: 18, height: 12))
        XCTAssertNoThrow(try ImageSanitizer.verifyCleanImage(at: result.outputURL))
    }

    func testPNGRemovesTextExifGPSAndUnknownAncillaryChunksLosslessly() throws {
        let sourceDirectory = try makeDirectory(named: "source")
        let outputDirectory = try makeDirectory(named: "output")
        let sourceURL = sourceDirectory.appendingPathComponent("transparent.png")
        try makeTaggedFixture(typeIdentifier: "public.png", at: sourceURL, orientation: 1)
        try insertPrivatePNGChunk(into: sourceURL)

        let originalData = try Data(contentsOf: sourceURL)
        let sourceImageData = try pngChunkPayloads(named: "IDAT", at: sourceURL)
        XCTAssertTrue(try metadataDescription(at: sourceURL).contains("SECRET_"))
        XCTAssertTrue(originalData.range(of: Data("SECRET_PRIVATE_CHUNK".utf8)) != nil)

        let result = try ImageSanitizer.stripMetadata(from: sourceURL, into: outputDirectory)
        let cleanedData = try Data(contentsOf: result.outputURL)

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        XCTAssertEqual(try pngChunkPayloads(named: "IDAT", at: result.outputURL), sourceImageData)
        XCTAssertNil(cleanedData.range(of: Data("SECRET_PRIVATE_CHUNK".utf8)))
        XCTAssertFalse(try metadataDescription(at: result.outputURL).contains("SECRET_"))
        XCTAssertEqual(try dimensions(at: result.outputURL), CGSize(width: 18, height: 12))
        XCTAssertTrue(try hasAlpha(at: result.outputURL))
        XCTAssertNoThrow(try ImageSanitizer.verifyCleanImage(at: result.outputURL))
    }

    func testTIFFRemovesPrivateMetadataAndPreservesDecodedPixels() throws {
        let sourceDirectory = try makeDirectory(named: "source")
        let outputDirectory = try makeDirectory(named: "output")
        let sourceURL = sourceDirectory.appendingPathComponent("scan.tiff")
        try makeTaggedFixture(typeIdentifier: "public.tiff", at: sourceURL, orientation: 1)

        let originalData = try Data(contentsOf: sourceURL)
        let originalPixels = try renderedRGBA(at: sourceURL)
        XCTAssertTrue(try metadataDescription(at: sourceURL).contains("SECRET_"))

        let result = try ImageSanitizer.stripMetadata(from: sourceURL, into: outputDirectory)

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        XCTAssertEqual(try renderedRGBA(at: result.outputURL), originalPixels)
        XCTAssertFalse(try metadataDescription(at: result.outputURL).contains("SECRET_"))
        XCTAssertEqual(try dimensions(at: result.outputURL), CGSize(width: 18, height: 12))
        XCTAssertTrue(try hasAlpha(at: result.outputURL))
        XCTAssertNoThrow(try ImageSanitizer.verifyCleanImage(at: result.outputURL))
    }

    func testExistingFilesAreNeverOverwritten() throws {
        let sourceDirectory = try makeDirectory(named: "source")
        let outputDirectory = try makeDirectory(named: "output")
        let sourceURL = sourceDirectory.appendingPathComponent("image.jpg")
        try makeTaggedFixture(typeIdentifier: "public.jpeg", at: sourceURL, orientation: 1)

        let occupiedURL = outputDirectory.appendingPathComponent("image.jpg")
        let occupiedData = Data("DO NOT REPLACE".utf8)
        try occupiedData.write(to: occupiedURL)

        let first = try ImageSanitizer.stripMetadata(from: sourceURL, into: outputDirectory)
        let second = try ImageSanitizer.stripMetadata(from: sourceURL, into: outputDirectory)

        XCTAssertEqual(try Data(contentsOf: occupiedURL), occupiedData)
        XCTAssertEqual(first.outputURL.lastPathComponent, "image clean.jpg")
        XCTAssertEqual(second.outputURL.lastPathComponent, "image clean 2.jpg")
    }

    func testSameFolderOutputLeavesOriginalUntouched() throws {
        let directory = try makeDirectory(named: "images")
        let sourceURL = directory.appendingPathComponent("image.png")
        try makeTaggedFixture(typeIdentifier: "public.png", at: sourceURL, orientation: 1)
        let originalData = try Data(contentsOf: sourceURL)

        let result = try ImageSanitizer.stripMetadata(from: sourceURL, into: directory)

        XCTAssertEqual(result.outputURL.lastPathComponent, "image clean.png")
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    func testUnsupportedAndCorruptFilesFailClearly() throws {
        let textURL = temporaryDirectory.appendingPathComponent("not-an-image.jpg")
        try Data("plain text".utf8).write(to: textURL)
        XCTAssertThrowsError(try ImageSanitizer.inspect(textURL)) { error in
            XCTAssertEqual(error as? ImageSanitizerError, .unreadableImage)
        }

        let gifURL = temporaryDirectory.appendingPathComponent("still.gif")
        try makeTaggedFixture(typeIdentifier: "com.compuserve.gif", at: gifURL, orientation: 1)
        XCTAssertThrowsError(try ImageSanitizer.inspect(gifURL)) { error in
            XCTAssertEqual(error as? ImageSanitizerError, .unsupportedFormat)
        }
    }

    func testHEICRemovesInjectedMetadataWhenSystemFixtureIsAvailable() throws {
        let systemFixture = URL(
            fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/Valley Light.heic"
        )
        guard FileManager.default.fileExists(atPath: systemFixture.path) else {
            throw XCTSkip("The macOS HEIC fixture is not present on this system.")
        }

        let sourceDirectory = try makeDirectory(named: "source")
        let outputDirectory = try makeDirectory(named: "output")
        let taggedURL = sourceDirectory.appendingPathComponent("tagged.heic")
        try addMetadataLosslessly(to: systemFixture, outputURL: taggedURL)
        XCTAssertTrue(try metadataDescription(at: taggedURL).contains("SECRET_"))

        let result = try ImageSanitizer.stripMetadata(from: taggedURL, into: outputDirectory)

        XCTAssertFalse(try metadataDescription(at: result.outputURL).contains("SECRET_"))
        XCTAssertEqual(try dimensions(at: result.outputURL), try dimensions(at: taggedURL))
        XCTAssertNoThrow(try ImageSanitizer.verifyCleanImage(at: result.outputURL))
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTaggedFixture(typeIdentifier: String, at url: URL, orientation: Int) throws {
        let image = try makeImage()
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw TestError.couldNotCreateFixture
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: "SECRET_ARTIST",
                kCGImagePropertyTIFFCopyright: "SECRET_COPYRIGHT",
                kCGImagePropertyTIFFDateTime: "2026:01:02 03:04:05",
                kCGImagePropertyTIFFImageDescription: "SECRET_DESCRIPTION",
                kCGImagePropertyTIFFMake: "SECRET_MAKE",
                kCGImagePropertyTIFFModel: "SECRET_MODEL",
                kCGImagePropertyTIFFSoftware: "SECRET_SOFTWARE",
                kCGImagePropertyTIFFOrientation: orientation
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05",
                kCGImagePropertyExifUserComment: "SECRET_EXIF_COMMENT"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 39.1,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 84.5,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ]
        if typeIdentifier == "public.png" {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGAuthor: "SECRET_PNG_AUTHOR",
                kCGImagePropertyPNGCreationTime: "2026-01-02T03:04:05Z",
                kCGImagePropertyPNGDescription: "SECRET_PNG_DESCRIPTION",
                kCGImagePropertyPNGSoftware: "SECRET_PNG_SOFTWARE",
                kCGImagePropertyPNGTitle: "SECRET_PNG_TITLE"
            ]
        }
        if typeIdentifier == "public.jpeg" {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.couldNotCreateFixture
        }
    }

    private func addMetadataLosslessly(to inputURL: URL, outputURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, type, 1, nil)
        else {
            throw TestError.couldNotCreateFixture
        }

        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(
            metadata,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyTIFFMake,
            "SECRET_HEIC_MAKE" as CFString
        ))
        XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(
            metadata,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSLatitude,
            NSNumber(value: 39.1)
        ))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            metadata,
            nil,
            "xmp:CreatorTool" as CFString,
            "SECRET_HEIC_XMP" as CFString
        ))

        var error: Unmanaged<CFError>?
        let options = [kCGImageDestinationMetadata: metadata] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
            if let error {
                throw error.takeRetainedValue()
            }
            throw TestError.couldNotCreateFixture
        }
    }

    private func makeImage() throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: 18,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 18 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.couldNotCreateFixture
        }
        context.setFillColor(CGColor(red: 0.08, green: 0.35, blue: 0.72, alpha: 0.45))
        context.fill(CGRect(x: 0, y: 0, width: 9, height: 12))
        context.setFillColor(CGColor(red: 0.88, green: 0.24, blue: 0.16, alpha: 0.9))
        context.fill(CGRect(x: 9, y: 0, width: 9, height: 12))
        guard let image = context.makeImage() else {
            throw TestError.couldNotCreateFixture
        }
        return image
    }

    private func imageSource(at url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TestError.couldNotReadFixture
        }
        return source
    }

    private func metadataDescription(at url: URL) throws -> String {
        let source = try imageSource(at: url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as Any
        let tags: Any
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            tags = CGImageMetadataCopyTags(metadata) as Any
        } else {
            tags = "none"
        }
        return "\(properties)\n\(tags)"
    }

    private func dimensions(at url: URL) throws -> CGSize {
        let source = try imageSource(at: url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw TestError.couldNotReadFixture
        }
        return CGSize(width: width.intValue, height: height.intValue)
    }

    private func orientation(at url: URL) throws -> Int {
        let source = try imageSource(at: url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? NSNumber
        else {
            return 1
        }
        return orientation.intValue
    }

    private func hasAlpha(at url: URL) throws -> Bool {
        let source = try imageSource(at: url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
    }

    private func renderedRGBA(at url: URL) throws -> Data {
        let source = try imageSource(at: url)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TestError.couldNotReadFixture
        }
        let width = image.width
        let height = image.height
        var bytes = Data(count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw TestError.couldNotReadFixture
        }
        return bytes
    }

    private func insertPrivatePNGChunk(into url: URL) throws {
        var data = try Data(contentsOf: url)
        let payload = Data("SECRET_PRIVATE_CHUNK".utf8)
        let type = Data("meTa".utf8)
        var chunk = Data()
        appendBigEndian(UInt32(payload.count), to: &chunk)
        chunk.append(type)
        chunk.append(payload)
        appendBigEndian(crc32(type + payload), to: &chunk)

        let insertionOffset = 8 + 12 + 13
        guard data.count > insertionOffset,
              String(bytes: data[12..<16], encoding: .ascii) == "IHDR"
        else {
            throw TestError.couldNotReadFixture
        }
        data.insert(contentsOf: chunk, at: insertionOffset)
        try data.write(to: url)
    }

    private func pngChunkPayloads(named requestedType: String, at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var result = Data()
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let count = Int(length)
            guard count <= data.count - offset - 12 else {
                throw TestError.couldNotReadFixture
            }
            let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if type == requestedType {
                result.append(contentsOf: data[(offset + 8)..<(offset + 8 + count)])
            }
            offset += count + 12
        }
        return result
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return ~crc
    }

    private enum TestError: Error {
        case couldNotCreateFixture
        case couldNotReadFixture
    }
}
