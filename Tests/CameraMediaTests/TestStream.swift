import AVFoundation
import Baichuan
import CoreMedia
import Foundation
import VideoToolbox
import XCTest

/// Produces what a camera would send: Annex B video from a real encoder and ADTS-framed AAC,
/// so the recorder can be tested without a camera.
enum TestStream {
    struct Frame {
        let data: Data
        let isKeyFrame: Bool
    }

    /// Encodes `count` frames of a moving bar. Throws `XCTSkip` when the Mac has no encoder
    /// for the codec.
    static func video(codec: VideoCodec, count: Int, width: Int = 320, height: Int = 240, keyFrameInterval: Int = 10) throws -> [Frame] {
        let type = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw XCTSkip("no \(codec.rawValue) encoder (\(status))") }
        defer { VTCompressionSessionInvalidate(session) }
        // Cameras send no B frames; neither may the test stream.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let lock = NSLock()
        var frames: [Frame] = []
        for i in 0..<count {
            let pixels = try pixelBuffer(width: width, height: height, index: i)
            let properties = i % keyFrameInterval == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 25),
                duration: CMTime(value: 1, timescale: 25), frameProperties: properties, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let frame = annexB(sample, codec: codec) else { return }
                lock.lock()
                frames.append(frame)
                lock.unlock()
            }
            guard status == noErr else { throw XCTSkip("\(codec.rawValue) encoder refused a frame (\(status))") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock(); defer { lock.unlock() }
        guard frames.count == count else { throw XCTSkip("\(codec.rawValue) encoder returned \(frames.count) of \(count) frames") }
        return frames
    }

    private static func pixelBuffer(width: Int, height: Int, index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw XCTSkip("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bar = (index * 8) % width
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                let lit: UInt8 = abs(x - bar) < 20 ? 255 : 40
                p[0] = lit; p[1] = UInt8(y % 256); p[2] = 80; p[3] = 255
            }
        }
        return buffer
    }

    /// Converts an encoder's sample (AVCC, parameter sets in the format description) to the
    /// camera's form: start codes, parameter sets in front of every key frame.
    private static func annexB(_ sample: CMSampleBuffer, codec: VideoCodec) -> Frame? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if isKey {
            var count = 0
            if codec == .h264 {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if codec == .h264 {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                guard let pointer else { return nil }
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else { return nil }
        var i = 0
        while i + 4 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard length > 0, i + length <= bytes.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<i + length])
            i += length
        }
        return Frame(data: out, isKeyFrame: isKey)
    }

    /// Encodes a sine tone as AAC-LC and frames every packet with an ADTS header.
    static func audio(frames count: Int, sampleRate: Double = 16000) throws -> [Data] {
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw XCTSkip("no PCM format") }
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let aacFormat = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat),
              let rateIndex = ADTSHeader.sampleRates.firstIndex(of: sampleRate) else { throw XCTSkip("no AAC encoder") }
        var packets: [Data] = []
        var fed = 0
        // The encoder holds a few packets back, so feed a little more than is asked for.
        while packets.count < count, fed < count + 8 {
            let output = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            var handedOver = false
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if handedOver {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                handedOver = true
                let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024)!
                pcm.frameLength = 1024
                let channel = pcm.floatChannelData!.pointee
                for i in 0..<1024 {
                    channel[i] = 0.5 * sin(2 * .pi * 440 * Float(fed * 1024 + i) / Float(sampleRate))
                }
                outStatus.pointee = .haveData
                return pcm
            }
            fed += 1
            guard status != .error else { throw XCTSkip("AAC encoder failed: \(error?.localizedDescription ?? "?")") }
            guard output.byteLength > 0 else { continue }
            let payload = Data(bytes: output.data, count: Int(output.byteLength))
            packets.append(adts(payload, rateIndex: rateIndex, channels: 1))
        }
        guard packets.count == count else { throw XCTSkip("AAC encoder returned \(packets.count) of \(count) packets") }
        return packets
    }

    static func adts(_ payload: Data, rateIndex: Int, channels: Int) -> Data {
        let length = payload.count + 7
        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF
        header[1] = 0xF1  // MPEG-4, no CRC
        header[2] = UInt8(1 << 6 | rateIndex << 2 | channels >> 2)  // profile LC
        header[3] = UInt8((channels & 3) << 6 | length >> 11)
        header[4] = UInt8(length >> 3 & 0xFF)
        header[5] = UInt8((length & 7) << 5 | 0x1F)
        header[6] = 0xFC
        return Data(header) + payload
    }
}
