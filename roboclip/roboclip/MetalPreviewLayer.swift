import SwiftUI
import MetalKit

struct MetalPreviewLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
