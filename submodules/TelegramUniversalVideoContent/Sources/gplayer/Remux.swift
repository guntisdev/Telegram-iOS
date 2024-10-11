import CoreMedia
import AudioToolbox
import VideoToolbox

// READ on handling h264
// https://stackoverflow.com/questions/29525000/how-to-use-videotoolbox-to-decompress-h-264-video-stream

func handleNalu(naluArr: [(Int, [Data])], videoFormatDescription: CMVideoFormatDescription)  -> [CMSampleBuffer] {
    var samples: [CMSampleBuffer] = []

    for frameData in naluArr {
        let concatenatedNALUs = frameData.1.reduce(Data()) { $0 + $1 }

        // Create a single CMBlockBuffer for the entire frame (with all its NALUs)
        if let blockBuffer = createBlockBuffer(naluData: concatenatedNALUs) {
            let pts = CMTime(value: Int64(frameData.0), timescale: 1, flags: .valid, epoch: CMTimeEpoch(0))

            // Create a single CMSampleBuffer for the entire frame
            if let sampleBuffer = createSampleBuffer(blockBuffer: blockBuffer, formatDescription: videoFormatDescription, pts: pts) {
                samples.append(sampleBuffer)
//                print("Successfully created CMSampleBuffer for a frame.")
            }
        }
    }
    
    return samples
}

func createVideoFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
    var videoFormatDescription: CMVideoFormatDescription?

    // Convert the SPS and PPS Data into byte arrays
    let spsArray = [UInt8](sps)
    let ppsArray = [UInt8](pps)

    // Store references to the parameter sets in an array
    let parameterSetPointers: [UnsafePointer<UInt8>] = [spsArray, ppsArray].map { $0.withUnsafeBufferPointer { $0.baseAddress! } }
    
    // Store the parameter set sizes in an array
    let parameterSetSizes: [Int] = [spsArray.count, ppsArray.count]

    // Call CMVideoFormatDescriptionCreateFromH264ParameterSets
    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault,
        parameterSetCount: 2,                             // We have two parameter sets: SPS and PPS
        parameterSetPointers: parameterSetPointers,       // Array of pointers to SPS and PPS
        parameterSetSizes: parameterSetSizes,             // Array of sizes for SPS and PPS
        nalUnitHeaderLength: 4,                           // Length of the NAL unit header (usually 4 bytes)
        formatDescriptionOut: &videoFormatDescription     // Output parameter to store the format description
    )

    if status == noErr {
        return videoFormatDescription
    } else {
        print("Error creating CMVideoFormatDescription: \(status)")
        return nil
    }
}

func createBlockBuffer(naluData: Data) -> CMBlockBuffer? {
    var blockBuffer: CMBlockBuffer?

    // Create CMBlockBuffer with the NALU data
    let status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: UnsafeMutableRawPointer(mutating: (naluData as NSData).bytes),  // The NALU data
        blockLength: naluData.count,                                                  // Size of the data
        blockAllocator: kCFAllocatorNull,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: naluData.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )

    if status == kCMBlockBufferNoErr {
        return blockBuffer
    } else {
        print("Error creating CMBlockBuffer: \(status)")
        return nil
    }
}


func createSampleBuffer(blockBuffer: CMBlockBuffer, formatDescription: CMVideoFormatDescription, pts: CMTime) -> CMSampleBuffer? {
    var sampleBuffer: CMSampleBuffer?
    
    // Array to store one size for the sample (since it's just one NALU per block)
    let sampleSizeArray = [CMBlockBufferGetDataLength(blockBuffer)]
    
    // Create CMSampleBuffer
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,                               // The CMBlockBuffer containing the NALU data
        formatDescription: formatDescription,                  // CMVideoFormatDescription for H.264
        sampleCount: 1,                                         // One sample (frame) per buffer
        sampleTimingEntryCount: 1,
        sampleTimingArray: [CMSampleTimingInfo(duration: CMTime.invalid, presentationTimeStamp: pts, decodeTimeStamp: CMTime.invalid)],
        sampleSizeEntryCount: 1,
        sampleSizeArray: sampleSizeArray,                      // The size of the sample
        sampleBufferOut: &sampleBuffer
    )
    
    if status == noErr {
        return sampleBuffer
    } else {
        print("Error creating CMSampleBuffer: \(status)")
        return nil
    }
}



// Audio
func createAudioFormatDescription(
    sampleRate: Float64, // e.g., 44100.0 Hz
    channelCount: UInt32, // e.g., 2 channels
    audioObjectType: UInt32, // AAC Object Type (e.g., 2 for AAC-LC)
    audioSpecificConfig: [UInt8] // Byte array from the esds atom
) -> CMAudioFormatDescription? {
    
    // Audio stream basic description
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatMPEG4AAC, // AAC format ID
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: 1024, // AAC usually has 1024 frames per packet
        mBytesPerFrame: 0,
        mChannelsPerFrame: channelCount, // e.g., 2 for stereo
        mBitsPerChannel: 0,
        mReserved: 0
    )
    
    // AAC-specific configuration data
    let audioSpecificConfigData = NSData(bytes: audioSpecificConfig, length: audioSpecificConfig.count)
    
    // Create Audio Format Description
    var formatDescription: CMAudioFormatDescription?
    let result = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0, // No specific channel layout size
        layout: nil, // No specific channel layout
        magicCookieSize: audioSpecificConfig.count, // Size of AudioSpecificConfig data
        magicCookie: audioSpecificConfigData.bytes, // Pass the AudioSpecificConfig
        extensions: nil, // No extensions
        formatDescriptionOut: &formatDescription
    )
    
    // Check for success
    if result == noErr {
        return formatDescription
    } else {
        print("Failed to create CMAudioFormatDescription with error: \(result)")
        return nil
    }
}
