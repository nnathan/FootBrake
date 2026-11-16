import Foundation

/// HEVC in an MP4 or MOV is labelled either `hvc1` (parameter sets in the
/// sample description) or `hev1` (parameter sets may also be in the stream).
/// Apple's decoders, and so AVPlayer and AVAssetReader, only accept `hvc1`,
/// and fail `hev1` with "Cannot Decode" (-11833). Files made by ffmpeg are
/// often `hev1` while still carrying the VPS, SPS and PPS in their `hvcC`
/// box; relabelling those as `hvc1` is all it takes (like `ffmpeg -tag:v hvc1`).
public enum HEVCTagFixer {
    public enum Result: Equatable, Sendable {
        /// No `hev1` video in the file.
        case notNeeded
        /// Relabelled in place; the file now decodes on Apple devices.
        case fixed
        /// `hev1` without parameter sets in `hvcC`, so relabelling wouldn't help.
        case unsupported
    }

    /// Relabels `hev1` sample entries as `hvc1`, in place. Only the `moov`
    /// box is read, so this is quick even for very large files.
    @discardableResult
    public static func fixInPlace(_ url: URL) throws -> Result {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let (moovOffset, moov) = try readMoov(handle) else { return .notNeeded }
        let entries = hev1Entries(inMoov: moov)
        if entries.isEmpty { return .notNeeded }
        guard entries.allSatisfy(\.hasParameterSets) else { return .unsupported }
        for entry in entries {
            try handle.seek(toOffset: moovOffset + UInt64(entry.typeOffset))
            try handle.write(contentsOf: Data("hvc1".utf8))
        }
        try handle.synchronize()
        return .fixed
    }

    // MARK: - Box parsing

    struct Hev1Entry: Equatable {
        /// Offset of the `hev1` type field, from the start of `moov`.
        let typeOffset: Int
        let hasParameterSets: Bool
    }

    /// The `moov` box's file offset and bytes (header included).
    private static func readMoov(_ handle: FileHandle) throws -> (UInt64, Data)? {
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return nil }
            var size = UInt64(header.uint32(at: 0))
            if size == 1 {
                guard header.count == 16 else { return nil }
                size = header.uint64(at: 8)
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= 8, offset + size <= fileSize else { return nil }
            if header.fourCC(at: 4) == "moov" {
                try handle.seek(toOffset: offset)
                guard let moov = try handle.read(upToCount: Int(size)), moov.count == Int(size) else { return nil }
                return (offset, moov)
            }
            offset += size
        }
        return nil
    }

    /// Every `hev1` sample entry under moov/trak/mdia/minf/stbl/stsd.
    static func hev1Entries(inMoov moov: Data) -> [Hev1Entry] {
        var found: [Hev1Entry] = []
        func walk(_ range: Range<Int>, path: [String]) {
            for box in boxes(in: moov, range) {
                switch (path.last, box.type) {
                case (nil, "moov"), ("moov", "trak"), ("trak", "mdia"), ("mdia", "minf"), ("minf", "stbl"):
                    walk(box.contentStart..<box.end, path: path + [box.type])
                case ("stbl", "stsd"):
                    // Full box: version/flags and entry count before the entries.
                    let entries = box.contentStart + 8
                    guard entries <= box.end else { continue }
                    for entry in boxes(in: moov, entries..<box.end) where entry.type == "hev1" {
                        found.append(Hev1Entry(typeOffset: entry.start + 4,
                                               hasParameterSets: hasParameterSets(moov, entry)))
                    }
                default:
                    continue
                }
            }
        }
        walk(0..<moov.count, path: [])
        return found
    }

    /// Whether the entry's `hvcC` lists at least one VPS, SPS and PPS.
    private static func hasParameterSets(_ data: Data, _ entry: Box) -> Bool {
        // A visual sample entry has 78 bytes of fields before its child boxes.
        let children = entry.contentStart + 78
        guard children <= entry.end,
              let hvcC = boxes(in: data, children..<entry.end).first(where: { $0.type == "hvcC" })
        else { return false }
        // 22 bytes of configuration, then the NAL unit arrays.
        var p = hvcC.contentStart + 22
        guard p < hvcC.end else { return false }
        let arrayCount = Int(data[p])
        p += 1
        var types: Set<UInt8> = []
        for _ in 0..<arrayCount {
            guard p + 3 <= hvcC.end else { return false }
            let type = data[p] & 0x3F
            let count = Int(data.uint16(at: p + 1))
            p += 3
            for _ in 0..<count {
                guard p + 2 <= hvcC.end else { return false }
                p += 2 + Int(data.uint16(at: p))
            }
            guard p <= hvcC.end else { return false }
            if count > 0 { types.insert(type) }
        }
        return types.isSuperset(of: [32, 33, 34])   // VPS, SPS, PPS
    }

    struct Box {
        let type: String
        let start: Int
        let contentStart: Int
        let end: Int
    }

    /// The boxes laid end to end in `range`, stopping at the first malformed one.
    private static func boxes(in data: Data, _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(data.uint32(at: offset))
            var headerSize = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                size = Int(clamping: data.uint64(at: offset + 8))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize, offset + size <= range.upperBound else { break }
            result.append(Box(type: data.fourCC(at: offset + 4), start: offset,
                              contentStart: offset + headerSize, end: offset + size))
            offset += size
        }
        return result
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (0..<4).reduce(0) { $0 << 8 | UInt32(self[i + $1]) }
    }

    func uint64(at offset: Int) -> UInt64 {
        let i = startIndex + offset
        return (0..<8).reduce(0) { $0 << 8 | UInt64(self[i + $1]) }
    }

    func fourCC(at offset: Int) -> String {
        let i = startIndex + offset
        return String(decoding: self[i..<i + 4], as: UTF8.self)
    }
}
