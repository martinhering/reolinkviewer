import AppKit
import AVFoundation
import SwiftUI

/// Hosts the renderer's AVSampleBufferDisplayLayer. The layer is added as a sublayer so it
/// can move between views (grid tile and single view). While SwiftUI swaps those views the
/// old and the new one exist side by side, torn down and built in either order, so the
/// renderer records which view owns its layer: the newest view claims it, and only the
/// owner may remove it.
struct VideoView: NSViewRepresentable {
    let renderer: VideoRenderer
    /// `.resizeAspect` letterboxes a picture whose aspect ratio differs from the view's;
    /// `.resizeAspectFill` crops it instead (grid tiles).
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        view.gravity = gravity
        view.show(renderer, claim: true)
        return view
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.gravity = gravity
        nsView.show(renderer, claim: false)
    }

    static func dismantleNSView(_ nsView: VideoHostView, coordinator: ()) {
        nsView.release()
    }
}

final class VideoHostView: NSView {
    private var renderer: VideoRenderer?
    var gravity: AVLayerVideoGravity = .resizeAspect {
        didSet { if let renderer, renderer.host === self { renderer.layer.videoGravity = gravity } }
    }
    private static let debug = ProcessInfo.processInfo.environment["REOLINK_DEBUG"] != nil

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `renderer`'s layer. With `claim` this view becomes the owner even if another view
    /// holds the layer; without it, the view only shows the layer if nobody else owns it.
    func show(_ renderer: VideoRenderer, claim: Bool) {
        if self.renderer !== renderer {
            release()
            self.renderer = renderer
        }
        if claim || renderer.host == nil { renderer.host = self }
        guard renderer.host === self, let host = layer else { return }
        if renderer.layer.superlayer !== host {
            renderer.layer.removeFromSuperlayer()
            // Follow the host layer's size as well, in case a resize bypasses the overrides below.
            renderer.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.addSublayer(renderer.layer)
        }
        renderer.layer.videoGravity = gravity
        fitLayer()
    }

    /// Gives the layer up, removing it only if this view still owns it.
    func release() {
        guard let renderer else { return }
        if renderer.host === self {
            renderer.layer.removeFromSuperlayer()
            renderer.host = nil
        }
        self.renderer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let renderer { show(renderer, claim: false) }
    }

    // The layer arrives with the size of the view it came from (the single view, or a tile),
    // so size it on every change, not only when AppKit asks for layout.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitLayer()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        fitLayer()
    }

    override func layout() {
        super.layout()
        fitLayer()
    }

    private func fitLayer() {
        guard let renderer, renderer.host === self, renderer.layer.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = bounds
        CATransaction.commit()
        if Self.debug {
            NSLog("video host %p: bounds %@ layer %@ host layer %@", self, NSStringFromRect(bounds),
                  NSStringFromRect(renderer.layer.frame), NSStringFromRect(layer?.bounds ?? .zero))
        }
    }
}
