import AppKit
import SwiftUI

/// Hosts the renderer's AVSampleBufferDisplayLayer.
struct VideoView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = renderer.layer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
