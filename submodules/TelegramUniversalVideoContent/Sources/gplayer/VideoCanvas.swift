import UIKit
import AVFoundation

class VideoCanvasView: UIView {
    private var displayLink: CADisplayLink?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        setNeedsDisplay()
    }

    func draw(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async {
                self.layer.contents = cgImage
            }
        }
    }
}
