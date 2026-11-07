import AppKit
import SwiftUI

/// Hosts the renderer's AVSampleBufferDisplayLayer. The layer is added as a sublayer so it
/// can move between views (grid tile and single view) without two views claiming it.
struct VideoView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        view.attach(renderer.layer)
        return view
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.attach(renderer.layer)
    }

    static func dismantleNSView(_ nsView: VideoHostView, coordinator: ()) {
        nsView.detach()
    }
}

final class VideoHostView: NSView {
    private var videoLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ newLayer: CALayer) {
        guard videoLayer !== newLayer else { return }
        detach()
        newLayer.removeFromSuperlayer()
        layer?.addSublayer(newLayer)
        videoLayer = newLayer
        needsLayout = true
    }

    func detach() {
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
    }

    override func layout() {
        super.layout()
        guard let videoLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
