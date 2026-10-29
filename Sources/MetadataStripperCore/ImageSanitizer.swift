import CoreGraphics
import Foundation
import ImageIO

public struct ImageInspection: Equatable, Sendable {
    public let typeIdentifier: String
    public let formatName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int64
    public let hasAlpha: Bool
    public let colorProfileName: String?

    public init(
        typeIdentifier: String,
        formatName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64,
        hasAlpha: Bool,
        colorProfileName: String?
    ) {
        self.typeIdentifier = typeIdentifier
        self.formatName = formatName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.hasAlpha = hasAlpha
        self.colorProfileName = colorProfileName
    }
}

public struct SanitizationResult: Equatable, Sendable {
    public let outputURL: URL
    public let originalByteCount: Int64
    public let cleanedByteCount: Int64

    public init(outputURL: URL, originalByteCount: Int64, cleanedByteCount: Int64) {
        self.outputURL = outputURL
        self.originalByteCount = originalByteCount
        self.cleanedByteCount = cleanedByteCount
    }
}

public enum ImageSanitizerError: LocalizedError, Equatable, Sendable {
    case notAFile
    case unreadableImage
    case unsupportedFormat
    case multipleFrames(Int)
    case invalidDimensions
    case outputFolderUnavailable
    case couldNotCreateOutput
    case copyFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAFile:
            return "This item is not a readable file."
        case .unreadableImage:
            return "This file can’t be read as an image."
        case .unsupportedFormat:
            return "This image format isn’t supported. Use JPEG, PNG, HEIC, or TIFF."
        case let .multipleFrames(count):
            return "Animated and multi-page images aren’t supported. This file contains \(count) frames."
        case .invalidDimensions:
            return "This image does not report valid pixel dimensions."
        case .outputFolderUnavailable:
            return "The selected output folder isn’t available."
        case .couldNotCreateOutput:
            return "A clean copy could not be created in the selected folder."
        case let .copyFailed(message):
            return "Metadata could not be removed safely. \(message)"
        case let .verificationFailed(message):
            return "The clean copy did not pass verification. \(message)"
        }
    }
}

public enum ImageSanitizer {
    public static let supportedTypeIdentifiers: Set<String> = [
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.tiff"
    ]

    private static let allowedTechnicalTags: Set<String> = [
        "exif:ColorSpace",
        "exif:ComponentsConfiguration",
        "exif:ExifVersion",
        "exif:FlashpixVersion",
        "exif:PixelXDimension",
        "exif:PixelYDimension",
        "tiff:Compression",
        "tiff:Orientation",
        "tiff:PhotometricInterpretation",
        "tiff:ResolutionUnit",
        "tiff:TileLength",
        "tiff:TileWidth"
    ]

    public static func inspect(_ inputURL: URL) throws -> ImageInspection {
        guard inputURL.isFileURL else {
            throw ImageSanitizerError.notAFile
        }

        let values = try? inputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw ImageSanitizerError.notAFile
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, sourceOptions),
              let type = CGImageSourceGetType(source) as String?
        else {
            throw ImageSanitizerError.unreadableImage
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw ImageSanitizerError.unreadableImage
        }

        guard supportedTypeIdentifiers.contains(type),
              (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type) == true
        else {
            throw ImageSanitizerError.unsupportedFormat
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount == 1 else {
            throw ImageSanitizerError.multipleFrames(frameCount)
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = integerValue(properties[kCGImagePropertyPixelWidth]),
              let height = integerValue(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0
        else {
            throw ImageSanitizerError.invalidDimensions
        }

        return ImageInspection(
            typeIdentifier: type,
            formatName: displayName(for: type),
            pixelWidth: width,
            pixelHeight: height,
            byteCount: Int64(values?.fileSize ?? 0),
            hasAlpha: boolValue(properties[kCGImagePropertyHasAlpha]),
            colorProfileName: properties[kCGImagePropertyProfileName] as? String
        )
    }

    public static func stripMetadata(from inputURL: URL, into outputDirectory: URL) throws -> SanitizationResult {
        let inspection = try inspect(inputURL)
        var isDirectory: ObjCBool = false
        guard outputDirectory.isFileURL,
              FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ImageSanitizerError.outputFolderUnavailable
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, sourceOptions),
              let sourceType = CGImageSourceGetType(source)
        else {
            throw ImageSanitizerError.unreadableImage
        }

        let outputURL = uniqueOutputURL(for: inputURL, in: outputDirectory)
        let temporaryURL = temporaryOutputURL(for: outputURL, in: outputDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = orientationValue(in: sourceProperties)
        let expectedGainMapTypes = gainMapTypes(in: source)

        switch inspection.typeIdentifier {
        case "public.jpeg":
            try copyJPEGWithoutPersonalMetadata(
                source: source,
                sourceType: sourceType,
                orientation: orientation,
                to: temporaryURL
            )
        case "public.png" where orientation == nil || orientation == 1:
            try copyPNGWithoutPersonalMetadata(from: inputURL, to: temporaryURL)
        case "public.png", "public.heic", "public.tiff":
            try reencodeWithoutPersonalMetadata(
                source: source,
                sourceType: sourceType,
                typeIdentifier: inspection.typeIdentifier,
                orientation: orientation,
                to: temporaryURL
            )
        default:
            throw ImageSanitizerError.unsupportedFormat
        }

        try verify(
            outputURL: temporaryURL,
            expectedTypeIdentifier: inspection.typeIdentifier,
            expectedWidth: inspection.pixelWidth,
            expectedHeight: inspection.pixelHeight,
            expectedOrientation: orientation,
            expectedHasAlpha: inspection.hasAlpha,
            expectedColorProfileName: inspection.colorProfileName,
            expectedGainMapTypes: expectedGainMapTypes
        )

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            throw ImageSanitizerError.copyFailed(error.localizedDescription)
        }

        let cleanedValues = try? outputURL.resourceValues(forKeys: [.fileSizeKey])
        return SanitizationResult(
            outputURL: outputURL,
            originalByteCount: inspection.byteCount,
            cleanedByteCount: Int64(cleanedValues?.fileSize ?? 0)
        )
    }

    public static func verifyCleanImage(at outputURL: URL) throws {
        let inspection = try inspect(outputURL)
        try verify(
            outputURL: outputURL,
            expectedTypeIdentifier: inspection.typeIdentifier,
            expectedWidth: inspection.pixelWidth,
            expectedHeight: inspection.pixelHeight,
            expectedOrientation: nil,
            expectedHasAlpha: inspection.hasAlpha,
            expectedColorProfileName: inspection.colorProfileName,
            expectedGainMapTypes: gainMapTypes(in: CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        )
    }

    private static func verify(
        outputURL: URL,
        expectedTypeIdentifier: String,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedOrientation: Int?,
        expectedHasAlpha: Bool,
        expectedColorProfileName: String?,
        expectedGainMapTypes: Set<String>
    ) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, sourceOptions),
              let outputType = CGImageSourceGetType(source) as String?
        else {
            throw ImageSanitizerError.verificationFailed("The output file can’t be reopened.")
        }

        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw ImageSanitizerError.verificationFailed("The output file is incomplete.")
        }
        guard outputType == expectedTypeIdentifier else {
            throw ImageSanitizerError.verificationFailed("The file type changed unexpectedly.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageSanitizerError.verificationFailed("The frame count changed unexpectedly.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              integerValue(properties[kCGImagePropertyPixelWidth]) == expectedWidth,
              integerValue(properties[kCGImagePropertyPixelHeight]) == expectedHeight
        else {
            throw ImageSanitizerError.verificationFailed("The pixel dimensions changed unexpectedly.")
        }

        guard boolValue(properties[kCGImagePropertyHasAlpha]) == expectedHasAlpha else {
            throw ImageSanitizerError.verificationFailed("The transparency changed unexpectedly.")
        }

        if let expectedColorProfileName {
            guard properties[kCGImagePropertyProfileName] as? String == expectedColorProfileName else {
                throw ImageSanitizerError.verificationFailed("The color profile changed unexpectedly.")
            }
        }

        guard gainMapTypes(in: source) == expectedGainMapTypes else {
            throw ImageSanitizerError.verificationFailed("The HDR rendering data changed unexpectedly.")
        }

        if let expectedOrientation, expectedOrientation >= 2, expectedOrientation <= 8 {
            guard orientationValue(in: properties) == expectedOrientation else {
                throw ImageSanitizerError.verificationFailed("The display orientation changed unexpectedly.")
            }
        }

        let tags: [CGImageMetadataTag]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []
        } else {
            tags = []
        }

        let unexpectedTags = tags.compactMap { tag -> String? in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?
            else {
                return "unknown metadata"
            }
            let qualifiedName = "\(prefix):\(name)"
            return allowedTechnicalTags.contains(qualifiedName) ? nil : qualifiedName
        }
        guard unexpectedTags.isEmpty else {
            throw ImageSanitizerError.verificationFailed(
                "Optional metadata remained: \(unexpectedTags.sorted().joined(separator: ", "))."
            )
        }


        if expectedTypeIdentifier == "public.png" {
            let forbiddenChunks = try personalPNGChunks(
                in: outputURL,
                allowOrientationExif: expectedOrientation.map { $0 >= 2 && $0 <= 8 } ?? false
            )
            guard forbiddenChunks.isEmpty else {
                throw ImageSanitizerError.verificationFailed(
                    "Personal PNG chunks remained: \(forbiddenChunks.sorted().joined(separator: ", "))."
                )
            }
        } else if expectedTypeIdentifier == "public.jpeg" {
            let forbiddenSegments = try personalJPEGSegments(in: outputURL)
            guard forbiddenSegments.isEmpty else {
                throw ImageSanitizerError.verificationFailed(
                    "Personal JPEG segments remained: \(forbiddenSegments.sorted().joined(separator: ", "))."
                )
            }
        }
    }

    private static func copyJPEGWithoutPersonalMetadata(
        source: CGImageSource,
        sourceType: CFString,
        orientation: Int?,
        to outputURL: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, sourceType, 1, nil) else {
            throw ImageSanitizerError.couldNotCreateOutput
        }

        let minimalMetadata = CGImageMetadataCreateMutable()
        if let orientation, orientation >= 2, orientation <= 8 {
            _ = CGImageMetadataSetValueMatchingImageProperty(
                minimalMetadata,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyTIFFOrientation,
                NSNumber(value: orientation)
            )
        }

        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: minimalMetadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true
        ]
        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination,
            source,
            options as CFDictionary,
            &copyError
        ) else {
            let detail = copyError?.takeRetainedValue().localizedDescription ?? "The JPEG encoder rejected the file."
            throw ImageSanitizerError.copyFailed(detail)
        }
        try sanitizeJPEGContainer(at: outputURL)
    }

    private static func reencodeWithoutPersonalMetadata(
        source: CGImageSource,
        sourceType: CFString,
        typeIdentifier: String,
        orientation: Int?,
        to outputURL: URL
    ) throws {
        let sourceOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, sourceType, 1, nil)
        else {
            throw ImageSanitizerError.couldNotCreateOutput
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: false
        ]
        if let orientation, orientation >= 2, orientation <= 8 {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if typeIdentifier == "public.heic" {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        } else if typeIdentifier == "public.tiff" {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: 5
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if typeIdentifier == "public.heic" {
            copyCleanGainMaps(from: source, to: destination)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ImageSanitizerError.copyFailed("The image encoder could not finish the clean copy.")
        }
    }

    private static func copyPNGWithoutPersonalMetadata(from inputURL: URL, to outputURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        } catch {
            throw ImageSanitizerError.copyFailed(error.localizedDescription)
        }

        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.count >= signature.count, data.prefix(signature.count) == signature else {
            throw ImageSanitizerError.copyFailed("The PNG signature is invalid.")
        }

        let safeAncillaryChunks: Set<String> = [
            "bKGD", "cHRM", "gAMA", "hIST", "iCCP", "pHYs", "sBIT", "sPLT", "sRGB", "tRNS"
        ]
        var output = Data(signature)
        var offset = signature.count
        var sawHeader = false
        var sawEnd = false

        while offset < data.count {
            guard data.count - offset >= 12 else {
                throw ImageSanitizerError.copyFailed("The PNG chunk table is incomplete.")
            }
            let length = try pngChunkLength(in: data, at: offset)
            guard length <= data.count - offset - 12 else {
                throw ImageSanitizerError.copyFailed("A PNG chunk extends beyond the file.")
            }

            let typeStart = offset + 4
            let typeEnd = typeStart + 4
            let typeBytes = data[typeStart..<typeEnd]
            guard typeBytes.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
            }), let type = String(bytes: typeBytes, encoding: .ascii) else {
                throw ImageSanitizerError.copyFailed("A PNG chunk has an invalid type.")
            }

            let chunkEnd = offset + 12 + length
            if !sawHeader {
                guard type == "IHDR", length == 13 else {
                    throw ImageSanitizerError.copyFailed("The PNG header is invalid.")
                }
                sawHeader = true
            }

            let isCritical = typeBytes.first.map { ($0 & 0x20) == 0 } ?? false
            if isCritical || safeAncillaryChunks.contains(type) {
                output.append(contentsOf: data[offset..<chunkEnd])
            }

            offset = chunkEnd
            if type == "IEND" {
                guard length == 0, offset == data.count else {
                    throw ImageSanitizerError.copyFailed("The PNG end marker is invalid.")
                }
                sawEnd = true
                break
            }
        }

        guard sawHeader, sawEnd else {
            throw ImageSanitizerError.copyFailed("The PNG file is incomplete.")
        }

        do {
            try output.write(to: outputURL, options: .withoutOverwriting)
        } catch {
            throw ImageSanitizerError.copyFailed(error.localizedDescription)
        }
    }

    private static func personalPNGChunks(in url: URL, allowOrientationExif: Bool) throws -> Set<String> {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let signatureCount = 8
        guard data.count >= signatureCount else {
            throw ImageSanitizerError.verificationFailed("The PNG file is incomplete.")
        }

        var allowedAncillary: Set<String> = [
            "bKGD", "cHRM", "gAMA", "hIST", "iCCP", "pHYs", "sBIT", "sPLT", "sRGB", "tRNS"
        ]
        if allowOrientationExif {
            allowedAncillary.insert("eXIf")
        }
        var found: Set<String> = []
        var offset = signatureCount
        while offset < data.count {
            guard data.count - offset >= 12 else {
                throw ImageSanitizerError.verificationFailed("The PNG chunk table is incomplete.")
            }
            let length = try pngChunkLength(in: data, at: offset)
            guard length <= data.count - offset - 12 else {
                throw ImageSanitizerError.verificationFailed("A PNG chunk extends beyond the file.")
            }
            let typeBytes = data[(offset + 4)..<(offset + 8)]
            if let type = String(bytes: typeBytes, encoding: .ascii) {
                let isCritical = typeBytes.first.map { ($0 & 0x20) == 0 } ?? false
                if !isCritical, !allowedAncillary.contains(type) {
                    found.insert(type)
                }
            }
            offset += 12 + length
        }
        return found
    }

    private static func sanitizeJPEGContainer(at url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImageSanitizerError.copyFailed(error.localizedDescription)
        }
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
            throw ImageSanitizerError.copyFailed("The JPEG header is invalid.")
        }

        var output = Data([0xFF, 0xD8])
        var offset = 2
        while offset < data.count {
            let markerStart = offset
            guard data[offset] == 0xFF else {
                throw ImageSanitizerError.copyFailed("The JPEG marker table is invalid.")
            }
            while offset < data.count, data[offset] == 0xFF {
                offset += 1
            }
            guard offset < data.count else {
                throw ImageSanitizerError.copyFailed("The JPEG marker table is incomplete.")
            }
            let marker = data[offset]
            offset += 1

            if marker == 0xDA {
                guard data.count - offset >= 2 else {
                    throw ImageSanitizerError.copyFailed("The JPEG scan header is incomplete.")
                }
                let scanHeaderLength = Int(data[offset]) << 8 | Int(data[offset + 1])
                guard scanHeaderLength >= 2, scanHeaderLength <= data.count - offset else {
                    throw ImageSanitizerError.copyFailed("The JPEG scan header is invalid.")
                }
                var cursor = offset + scanHeaderLength
                var endOffset: Int?
                while cursor + 1 < data.count {
                    if data[cursor] == 0xFF, data[cursor + 1] == 0xD9 {
                        endOffset = cursor + 2
                        break
                    }
                    cursor += 1
                }
                guard let endOffset else {
                    throw ImageSanitizerError.copyFailed("The JPEG end marker is missing.")
                }
                output.append(contentsOf: data[markerStart..<endOffset])
                offset = data.count
                break
            }
            if marker == 0xD9 {
                output.append(contentsOf: data[markerStart..<offset])
                break
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {
                output.append(contentsOf: data[markerStart..<offset])
                continue
            }

            guard data.count - offset >= 2 else {
                throw ImageSanitizerError.copyFailed("A JPEG segment length is missing.")
            }
            let segmentLength = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard segmentLength >= 2, segmentLength <= data.count - offset else {
                throw ImageSanitizerError.copyFailed("A JPEG segment extends beyond the file.")
            }
            let payloadStart = offset + 2
            let segmentEnd = offset + segmentLength
            let payload = data[payloadStart..<segmentEnd]

            switch marker {
            case 0xE0:
                if payload.starts(with: Data("JFIF\0".utf8)), payload.count >= 14 {
                    var normalized = Data(payload.prefix(14))
                    normalized[12] = 0
                    normalized[13] = 0
                    output.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
                    output.append(normalized)
                }
            case 0xE1:
                if payload.starts(with: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) {
                    output.append(contentsOf: data[markerStart..<segmentEnd])
                }
            case 0xE2:
                if payload.starts(with: Data("ICC_PROFILE\0".utf8)) {
                    output.append(contentsOf: data[markerStart..<segmentEnd])
                }
            case 0xEE:
                if payload.starts(with: Data("Adobe".utf8)) {
                    output.append(contentsOf: data[markerStart..<segmentEnd])
                }
            case 0xE3...0xED, 0xEF, 0xFE:
                break
            default:
                output.append(contentsOf: data[markerStart..<segmentEnd])
            }
            offset = segmentEnd
        }

        guard offset == data.count else {
            throw ImageSanitizerError.copyFailed("The JPEG file is incomplete.")
        }
        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw ImageSanitizerError.copyFailed(error.localizedDescription)
        }
    }

    private static func personalJPEGSegments(in url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
            throw ImageSanitizerError.verificationFailed("The JPEG header is invalid.")
        }
        guard data[data.count - 2] == 0xFF, data[data.count - 1] == 0xD9 else {
            throw ImageSanitizerError.verificationFailed("The JPEG file has trailing data.")
        }

        var found: Set<String> = []
        var offset = 2
        while offset < data.count {
            guard data[offset] == 0xFF else {
                throw ImageSanitizerError.verificationFailed("The JPEG marker table is invalid.")
            }
            while offset < data.count, data[offset] == 0xFF {
                offset += 1
            }
            guard offset < data.count else {
                throw ImageSanitizerError.verificationFailed("The JPEG marker table is incomplete.")
            }
            let marker = data[offset]
            offset += 1
            if marker == 0xDA || marker == 0xD9 {
                break
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {
                continue
            }
            guard data.count - offset >= 2 else {
                throw ImageSanitizerError.verificationFailed("A JPEG segment length is missing.")
            }
            let segmentLength = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard segmentLength >= 2, segmentLength <= data.count - offset else {
                throw ImageSanitizerError.verificationFailed("A JPEG segment extends beyond the file.")
            }
            let payload = data[(offset + 2)..<(offset + segmentLength)]

            if marker == 0xE0 {
                let xThumbnailIndex = payload.index(payload.startIndex, offsetBy: min(12, payload.count))
                let yThumbnailIndex = payload.index(payload.startIndex, offsetBy: min(13, payload.count))
                if !payload.starts(with: Data("JFIF\0".utf8))
                    || payload.count != 14
                    || xThumbnailIndex == payload.endIndex
                    || yThumbnailIndex == payload.endIndex
                    || payload[xThumbnailIndex] != 0
                    || payload[yThumbnailIndex] != 0
                {
                    found.insert("APP0")
                }
            } else if marker == 0xE1 {
                if !payload.starts(with: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) {
                    found.insert("APP1")
                }
            } else if marker == 0xE2 {
                if !payload.starts(with: Data("ICC_PROFILE\0".utf8)) {
                    found.insert("APP2")
                }
            } else if marker == 0xEE {
                if !payload.starts(with: Data("Adobe".utf8)) {
                    found.insert("APP14")
                }
            } else if (0xE3...0xED).contains(marker) || marker == 0xEF || marker == 0xFE {
                found.insert(marker == 0xFE ? "COM" : String(format: "APP%d", Int(marker - 0xE0)))
            }
            offset += segmentLength
        }
        return found
    }

    private static func pngChunkLength(in data: Data, at offset: Int) throws -> Int {
        guard data.count - offset >= 4 else {
            throw ImageSanitizerError.copyFailed("The PNG chunk length is missing.")
        }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Int(value)
    }

    private static func gainMapTypes(in source: CGImageSource?) -> Set<String> {
        guard let source else {
            return []
        }
        var result: Set<String> = []
        for type in gainMapDataTypes() {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
                result.insert(type as String)
            }
        }
        return result
    }

    private static func copyCleanGainMaps(from source: CGImageSource, to destination: CGImageDestination) {
        for type in gainMapDataTypes() {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type),
                  var cleanInfo = info as? [CFString: Any]
            else {
                continue
            }
            cleanInfo.removeValue(forKey: kCGImageAuxiliaryDataInfoMetadata)
            CGImageDestinationAddAuxiliaryDataInfo(destination, type, cleanInfo as CFDictionary)
        }
    }

    private static func gainMapDataTypes() -> [CFString] {
        var types = [kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15.0, *) {
            types.append(kCGImageAuxiliaryDataTypeISOGainMap)
        }
        return types
    }

    private static func orientationValue(in properties: [CFString: Any]?) -> Int? {
        guard let orientation = integerValue(properties?[kCGImagePropertyOrientation]),
              orientation >= 1,
              orientation <= 8
        else {
            return nil
        }
        return orientation
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let integer = value as? Int {
            return integer
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let boolean = value as? Bool {
            return boolean
        }
        return false
    }

    private static func uniqueOutputURL(for inputURL: URL, in outputDirectory: URL) -> URL {
        let fileManager = FileManager.default
        let originalName = inputURL.lastPathComponent
        let originalCandidate = outputDirectory.appendingPathComponent(originalName, isDirectory: false)

        if originalCandidate.standardizedFileURL != inputURL.standardizedFileURL,
           !fileManager.fileExists(atPath: originalCandidate.path)
        {
            return originalCandidate
        }

        let fileExtension = inputURL.pathExtension
        let stem = inputURL.deletingPathExtension().lastPathComponent
        var suffix = " clean"
        var counter = 2

        while true {
            let filename = fileExtension.isEmpty
                ? "\(stem)\(suffix)"
                : "\(stem)\(suffix).\(fileExtension)"
            let candidate = outputDirectory.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix = " clean \(counter)"
            counter += 1
        }
    }

    private static func temporaryOutputURL(for outputURL: URL, in outputDirectory: URL) -> URL {
        let fileExtension = outputURL.pathExtension
        let filename = fileExtension.isEmpty
            ? ".metadata-stripper-\(UUID().uuidString)"
            : ".metadata-stripper-\(UUID().uuidString).\(fileExtension)"
        return outputDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func displayName(for typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "public.jpeg":
            return "JPEG"
        case "public.png":
            return "PNG"
        case "public.heic":
            return "HEIC"
        case "public.tiff":
            return "TIFF"
        default:
            return "Image"
        }
    }
}
