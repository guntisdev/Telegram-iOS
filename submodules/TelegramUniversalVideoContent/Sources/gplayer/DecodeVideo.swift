import AVFoundation
import VideoToolbox

protocol VideoDecoder {
    func decode(_ sampleBuffer: CMSampleBuffer)
    func getFormatDescription() -> CMVideoFormatDescription
    func destroy()
}

func createVideoDecoder(
    _ formatDescription: CMVideoFormatDescription,
    _ pixelCallback: @escaping  (CVPixelBuffer, Int64) -> Void
) -> VideoDecoder? {
    var decompressionSession: VTDecompressionSession?
    var callbackRecord = VTDecompressionOutputCallbackRecord()

    // Store the pixelCallback in an unmanaged pointer
    let callbackPointer = Unmanaged.passRetained(CallbackWrapper(callback: pixelCallback))

    // Define a C-compatible callback that doesn't capture context
    callbackRecord.decompressionOutputCallback = { (outputCallbackRefCon, _, status, _, imageBuffer, pts, _) in
        if status == noErr, let imageBuffer = imageBuffer {
            // Retrieve the stored callback using the pointer passed via outputCallbackRefCon
            let callbackWrapper = Unmanaged<CallbackWrapper>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
            callbackWrapper.callback(imageBuffer, pts.value)
        } else {
            print("Error decoding frame: \(status)")
        }
    }
            
    // Pass the callback pointer as context
    callbackRecord.decompressionOutputRefCon = UnsafeMutableRawPointer(callbackPointer.toOpaque())

    // Create a dictionary of decoder configuration
    let destinationPixelBufferAttributes: [NSString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ]

    // Create the decompression session
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: formatDescription,
        decoderSpecification: nil,
        imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
        outputCallback: &callbackRecord,
        decompressionSessionOut: &decompressionSession
    )

    if status == noErr {
        return H264Decoder(decompressionSession: decompressionSession!, formatDescription: formatDescription)
    } else {
        print("Error creating VTDecompressionSession: \(status)")
        return nil
    }
}

struct H264Decoder: VideoDecoder {
    private var decompressionSession: VTDecompressionSession
    private var formatDescription: CMVideoFormatDescription
    
    init(decompressionSession: VTDecompressionSession, formatDescription: CMVideoFormatDescription) {
        self.decompressionSession = decompressionSession
        self.formatDescription = formatDescription
    }
    
    func getFormatDescription() -> CMVideoFormatDescription {
        return formatDescription
    }
    
    func decode(_ sampleBuffer: CMSampleBuffer) {
        let decodeFlags: VTDecodeFrameFlags = []
        var flagOut: VTDecodeInfoFlags = VTDecodeInfoFlags(rawValue: 0)

        let status = VTDecompressionSessionDecodeFrame(
            self.decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &flagOut
        )

        if status != noErr {
            print("Error decoding sample buffer: \(status)")
        }
    }
    
    func destroy() {
        VTDecompressionSessionInvalidate(self.decompressionSession)
    }
}


// Helper class to wrap the callback
class CallbackWrapper {
    let callback: (CVPixelBuffer, Int64) -> Void
    
    init(callback: @escaping (CVPixelBuffer, Int64) -> Void) {
        self.callback = callback
    }
    
    deinit {
        print("CallbackWrapper deallocated")
    }
}
