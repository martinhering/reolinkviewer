import Baichuan
import CoreMedia
import Foundation

/// Splits an Annex B byte stream into NAL units (start codes removed).
public enum AnnexB {
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var units: [Data] = []
        var start: Int? = nil
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s && bytes[end - 1] == 0 { end -= 1 }  // 4-byte start code
                    if end > s { units.append(Data(bytes[s..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < n { units.append(Data(bytes[s..<n])) }
        return units
    }
}

/// Turns the camera's H.264/H.265 access units (Annex B) into what CoreMedia wants: a format
/// description built from the parameter sets, and the slices in AVCC framing. Keeps the
/// parameter sets across frames and drops everything before the first key frame.
/// Used from one task at a time.
public final class VideoSampleBuilder {
    /// One decodable picture.
    public struct AccessUnit {
        /// The slices, each preceded by its 4-byte big-endian length.
        public let data: Data
        public let format: CMVideoFormatDescription
        public let isKeyFrame: Bool
        /// The format description was replaced since the previous access unit: the parameter
        /// sets changed. False for the first unit after a reset.
        public let formatChanged: Bool
    }

    private var codec: VideoCodec?
    private var parameterSets: [UInt8: Data] = [:]
    private var waitingForKeyFrame = true
    private var formatReplaced = false

    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var frameSize: CGSize = .zero

    public init() {}

    /// Forget the stream state; the next frame must be a key frame.
    public func reset() {
        codec = nil
        parameterSets = [:]
        formatDescription = nil
        waitingForKeyFrame = true
        formatReplaced = false
    }

    /// Drop frames until the next key frame, for example after the decoder failed.
    public func requireKeyFrame() {
        waitingForKeyFrame = true
    }

    /// Returns nil for frames that cannot be decoded on their own yet: before the parameter
    /// sets are complete, before the first key frame, or without any slice.
    public func accessUnit(codec: VideoCodec, data: Data, isKeyFrame: Bool) -> AccessUnit? {
        if self.codec != codec {
            reset()
            self.codec = codec
        }

        var slices: [Data] = []
        var parameterSetsChanged = false
        for nal in AnnexB.nalUnits(data) {
            guard let first = nal.first else { continue }
            switch codec {
            case .h264:
                let type = first & 0x1F
                switch type {
                case 7, 8:  // SPS, PPS
                    if parameterSets[type] != nal { parameterSets[type] = nal; parameterSetsChanged = true }
                case 1, 5:  // non-IDR / IDR slice
                    slices.append(nal)
                default:
                    break  // SEI, AUD, filler
                }
            case .h265:
                let type = (first >> 1) & 0x3F
                switch type {
                case 32, 33, 34:  // VPS, SPS, PPS
                    if parameterSets[type] != nal { parameterSets[type] = nal; parameterSetsChanged = true }
                case 0...31:
                    slices.append(nal)
                default:
                    break
                }
            }
        }

        if parameterSetsChanged || formatDescription == nil {
            if let fd = makeFormatDescription(codec) {
                if formatDescription != nil { formatReplaced = true }
                formatDescription = fd
                let dims = CMVideoFormatDescriptionGetDimensions(fd)
                frameSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            }
        }
        guard let fd = formatDescription, !slices.isEmpty else { return nil }
        if waitingForKeyFrame {
            guard isKeyFrame else { return nil }
            waitingForKeyFrame = false
        }

        // AVCC framing: 4-byte big-endian length before each NAL unit.
        var avcc = Data(capacity: data.count + 4 * slices.count)
        for nal in slices {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        defer { formatReplaced = false }
        return AccessUnit(data: avcc, format: fd, isKeyFrame: isKeyFrame, formatChanged: formatReplaced)
    }

    private func makeFormatDescription(_ codec: VideoCodec) -> CMVideoFormatDescription? {
        let sets: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps = parameterSets[7], let pps = parameterSets[8] else { return nil }
            sets = [[UInt8](sps), [UInt8](pps)]
        case .h265:
            guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return nil }
            sets = [[UInt8](vps), [UInt8](sps), [UInt8](pps)]
        }
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var fd: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        }
        guard status == noErr else {
            NSLog("format description failed: \(status)")
            return nil
        }
        return fd
    }

    /// Wraps an access unit in a sample buffer.
    /// - Parameter displayImmediately: for live view, show the frame as soon as it is decoded
    ///   and ignore the time stamp. Leave it off for recording.
    public static func sampleBuffer(_ unit: AccessUnit, presentationTime: CMTime, displayImmediately: Bool = false) -> CMSampleBuffer? {
        guard let block = makeBlockBuffer(unit.data) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sizes = [unit.data.count]
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: unit.format,
                                               sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if !unit.isKeyFrame {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// Copies `data` into a new block buffer.
func makeBlockBuffer(_ data: Data) -> CMBlockBuffer? {
    let length = data.count
    guard length > 0 else { return nil }
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer)
    guard status == noErr, let block = blockBuffer else { return nil }
    status = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    return status == noErr ? block : nil
}
