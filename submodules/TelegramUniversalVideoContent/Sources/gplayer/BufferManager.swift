import Foundation
import VideoToolbox

class BufferManager {
    private let canvas: VideoCanvasView
    private var frameArr: [(CVPixelBuffer, Int64)] = []
    
    // HACK hardcoding pts for now, before parsing them out
    private var currentPts: Int64 = 0

    init(_ canvas: VideoCanvasView) {
        self.canvas = canvas
    }
    
    public func pushFrame(pixelBuffer: CVPixelBuffer, pts: Int64) -> Void {
//        self.frameArr.append((pixelBuffer, pts))
        self.frameArr.append((pixelBuffer, self.currentPts))
        self.currentPts += 42
    }
    
    public func draw(_ pts: Int64) {
        var currentIndex: Int?
        for (i, videoFrame) in self.frameArr.enumerated() {
            if pts >= videoFrame.1 {
                currentIndex = i
            }
        }
        
        guard let drawIndex = currentIndex else {
            return
        }
        
        self.canvas.draw(self.frameArr[drawIndex].0)
        self.frameArr.removeSubrange(0...drawIndex)
        
        if drawIndex > 0 { print("Dropped video frames: \(drawIndex)") }
    }
    
    private func debug(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        // You can now access the pixel data in the pixel buffer
//        let width = CVPixelBufferGetWidth(pixelBuffer)
//        let height = CVPixelBufferGetHeight(pixelBuffer)
        // for lowest stream 416x234
//        print("Decoded frame with dimensions: \(width)x\(height)")
        
//        // Get the base address (pointer to the start of the pixel data)
//        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
//            // Cast the base address to a pointer to UInt8 (byte-level access)
//            let bufferPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
//
//            var i = 416*200
//            // Print the first four bytes
//            print(bufferPointer[i], bufferPointer[i+1], bufferPointer[i+2], bufferPointer[i+3])
//        }

        // Unlock when you're done
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
}
