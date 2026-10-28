import MetalKit
import SwiftUI

struct EarthPreviewView: NSViewRepresentable
{
    let renderer: EarthPreviewRenderer
    let revision: UInt64

    func makeNSView(context: Context) -> EarthMetalView
    {
        EarthMetalView(renderer: renderer)
    }

    func updateNSView(_ view: EarthMetalView, context: Context)
    {
        view.refresh()
    }
}

final class EarthMetalView: NSView
{
    private let renderer: EarthPreviewRenderer
    private let metalView: MTKView

    init(renderer: EarthPreviewRenderer)
    {
        self.renderer = renderer
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
        renderer.orbit(horizontal: Float(event.deltaX), vertical: Float(event.deltaY))
        refresh()
    }

    override func scrollWheel(with event: NSEvent)
    {
        renderer.zoom(delta: Float(event.scrollingDeltaY))
        refresh()
    }
}
