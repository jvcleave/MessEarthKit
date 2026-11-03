import MetalKit
import SwiftUI

struct EarthPreviewView: NSViewRepresentable
{
    let renderer: EarthPreviewRenderer
    let revision: UInt64
    var allowsPanning = false

    func makeNSView(context: Context) -> EarthMetalView
    {
        EarthMetalView(renderer: renderer, allowsPanning: allowsPanning)
    }

    func updateNSView(_ view: EarthMetalView, context: Context)
    {
        view.allowsPanning = allowsPanning
        view.refresh()
    }
}

final class EarthMetalView: NSView
{
    private let renderer: EarthPreviewRenderer
    private let metalView: MTKView
    var allowsPanning: Bool

    init(renderer: EarthPreviewRenderer, allowsPanning: Bool)
    {
        self.renderer = renderer
        self.allowsPanning = allowsPanning
        metalView = MTKView(frame: .zero, device: renderer.device)
        super.init(frame: .zero)
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColor(red: 0.025, green: 0.03, blue: 0.04, alpha: 1)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.delegate = renderer
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
    }

    required init?(coder: NSCoder)
    {
        return nil
    }

    func refresh()
    {
        metalView.needsDisplay = true
    }

    // Route viewport interaction to this owner while MetalKit owns only drawing.
    override func hitTest(_ point: NSPoint) -> NSView?
    {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDragged(with event: NSEvent)
    {
        if allowsPanning && event.modifierFlags.contains(.shift) { pan(event) }
        else { renderer.orbit(horizontal: Float(event.deltaX), vertical: Float(event.deltaY)) }
        refresh()
    }

    override func rightMouseDragged(with event: NSEvent)
    {
        guard allowsPanning else { return }
        pan(event)
        refresh()
    }

    override func otherMouseDragged(with event: NSEvent)
    {
        guard allowsPanning else { return }
        pan(event)
        refresh()
    }

    private func pan(_ event: NSEvent)
    {
        renderer.pan(horizontal: Float(event.deltaX), vertical: Float(event.deltaY), viewportHeight: Float(bounds.height), aspect: Float(bounds.width / max(1, bounds.height)))
    }

    override func scrollWheel(with event: NSEvent)
    {
        renderer.zoom(delta: Float(event.scrollingDeltaY))
        refresh()
    }
}
