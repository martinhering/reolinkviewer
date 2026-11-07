import AVFoundation
import Baichuan
import CoreMedia
import Foundation

/// Splits an Annex B byte stream into NAL units (start codes removed).
enum AnnexB {
    static func nalUnits(_ data: Data) -> [Data] {
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

/// Turns the camera's H.264/H.265 access units into CMSampleBuffers and hands them to an
/// AVSampleBufferDisplayLayer, which decodes with VideoToolbox and displays them.
/// Used from one decoding task at a time; `layer` is handed to the view on the main thread.
final class VideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    /// The view currently showing `layer`. Main thread only; see `VideoHostView`.
    weak var host: VideoHostView?
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    private var codec: VideoCodec?
    private var parameterSets: [UInt8: Data] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyFrame = true

    private(set) var framesEnqueued = 0
    private(set) var frameSize: CGSize = .zero
    private(set) var lastFrameTime: Date?

    var statusDescription: String {
        let r = renderer
        let status: String
        switch r.status {
        case .unknown: status = "unknown"
        case .rendering: status = "rendering"
        case .failed: status = "failed: \(r.error?.localizedDescription ?? "?")"
        @unknown default: status = "?"
        }
        return "frames=\(framesEnqueued) size=\(Int(frameSize.width))x\(Int(frameSize.height)) renderer=\(status)"
    }

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Forget the stream state; the next frame must be a key frame.
    func reset() {
        renderer.flush()
        codec = nil
        parameterSets = [:]
        formatDescription = nil
        waitingForKeyFrame = true
        lastFrameTime = Date()  // watchdog baseline for the new stream
    }

    func enqueue(_ frame: BCMediaFrame) {
        switch frame {
        case .videoKeyFrame(let codec, let data, let micros, _):
            push(codec: codec, data: data, microseconds: micros, isKeyFrame: true)
        case .videoFrame(let codec, let data, let micros):
            push(codec: codec, data: data, microseconds: micros, isKeyFrame: false)
        case .info, .aac, .adpcm:
            break
        }
    }

    private func push(codec: VideoCodec, data: Data, microseconds: UInt32, isKeyFrame: Bool) {
        if self.codec != codec {
            self.codec = codec
            parameterSets = [:]
            formatDescription = nil
            waitingForKeyFrame = true
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
                if formatDescription != nil { renderer.flush() }
                formatDescription = fd
                let dims = CMVideoFormatDescriptionGetDimensions(fd)
                frameSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            }
        }
        guard let fd = formatDescription, !slices.isEmpty else { return }
        if waitingForKeyFrame {
            guard isKeyFrame else { return }
            waitingForKeyFrame = false
        }

        // AVCC framing: 4-byte big-endian length before each NAL unit.
        var avcc = Data(capacity: data.count + 4 * slices.count)
        for nal in slices {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        guard let sample = makeSampleBuffer(avcc, format: fd, microseconds: microseconds, isKeyFrame: isKeyFrame) else { return }

        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
            if !isKeyFrame {
                waitingForKeyFrame = true
                return
            }
        }
        renderer.enqueue(sample)
        framesEnqueued += 1
        lastFrameTime = Date()
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

    private func makeSampleBuffer(_ avcc: Data, format: CMVideoFormatDescription, microseconds: UInt32, isKeyFrame: Bool) -> CMSampleBuffer? {
        let length = avcc.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let block = blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(microseconds), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sizes = [length]
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            // Live view: show each frame as soon as it is decoded, ignore timestamps.
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyFrame {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
