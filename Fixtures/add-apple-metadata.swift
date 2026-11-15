// Copies a movie (passthrough) adding QuickTime `mdta` capture metadata the way
// the iPhone camera writes it. Usage: swift add-apple-metadata.swift in.mov out.mov
import AVFoundation

func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
}

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)

guard let export = AVAssetExportSession(asset: AVURLAsset(url: input),
                                        presetName: AVAssetExportPresetPassthrough) else {
    fatalError("cannot create export session")
}
export.metadata = [
    item(.quickTimeMetadataCreationDate, "2026-11-15T17:49:14+1100"),
    item(.quickTimeMetadataLocationISO6709, "-33.8568+151.2153+005.000/"),
    item(.quickTimeMetadataMake, "Apple"),
    item(.quickTimeMetadataModel, "iPhone 17 Pro Max"),
    item(.quickTimeMetadataSoftware, "26.7.1"),
]
try await export.export(to: output, as: .mov)
