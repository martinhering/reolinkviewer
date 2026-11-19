import AVFoundation
import Foundation

/// A player item whose MP4 is held in memory. Recordings are decrypted in memory and must not
/// touch the disk in the clear, so AVFoundation reads them through a resource loader.
final class MemoryClipItem {
    let item: AVPlayerItem
    private let loader: Loader

    init(data: Data) {
        loader = Loader(data: data)
        let asset = AVURLAsset(url: URL(string: "rvclip://clip/\(UUID().uuidString).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: Loader.queue)
        item = AVPlayerItem(asset: asset)
    }

    private final class Loader: NSObject, AVAssetResourceLoaderDelegate {
        static let queue = DispatchQueue(label: "memory-clip")
        let data: Data

        init(data: Data) {
            self.data = data
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            if let info = request.contentInformationRequest {
                info.contentType = AVFileType.mp4.rawValue
                info.contentLength = Int64(data.count)
                info.isByteRangeAccessSupported = true
            }
            if let wanted = request.dataRequest {
                let offset = min(max(Int(wanted.currentOffset), 0), data.count)
                let length = wanted.requestsAllDataToEndOfResource ? data.count - offset
                    : min(wanted.requestedLength - Int(wanted.currentOffset - wanted.requestedOffset), data.count - offset)
                if length > 0 { wanted.respond(with: data.subdata(in: offset..<offset + length)) }
            }
            request.finishLoading()
            return true
        }
    }
}
