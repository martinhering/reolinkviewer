import AVFoundation
import Baichuan
import CameraMedia
import CoreMedia
import Foundation

/// Hands the camera's H.264/H.265 access units, wrapped in sample buffers by
/// `VideoSampleBuilder`, to an AVSampleBufferDisplayLayer, which decodes with VideoToolbox
/// and displays them.
/// Used from one decoding task at a time; `layer` is handed to the view on the main thread.
final class VideoRenderer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    /// The view currently showing `layer`. Main thread only; see `VideoHostView`.
    weak var host: VideoHostView?
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    private let builder = VideoSampleBuilder()

    private(set) var framesEnqueued = 0
    var frameSize: CGSize { builder.frameSize }
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
        builder.reset()
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
        guard let unit = builder.accessUnit(codec: codec, data: data, isKeyFrame: isKeyFrame) else { return }
        if unit.formatChanged { renderer.flush() }
        // Live view: show each frame as soon as it is decoded, ignore timestamps.
        let time = CMTime(value: CMTimeValue(microseconds), timescale: 1_000_000)
        guard let sample = VideoSampleBuilder.sampleBuffer(unit, presentationTime: time, displayImmediately: true) else { return }

        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
            if !isKeyFrame {
                builder.requireKeyFrame()
                return
            }
        }
        renderer.enqueue(sample)
        framesEnqueued += 1
        lastFrameTime = Date()
    }
}
