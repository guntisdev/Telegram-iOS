import AVFoundation
import AudioToolbox

// READ on audio decoding
// https://stackoverflow.com/questions/14263808/how-to-use-audioconverterfillcomplexbuffer-and-its-callback

protocol AudioDecoder {
    func decode(_ aacPackets: [Data], _ pts: Int64) -> (AVAudioPCMBuffer, Int64)?
    func destroy()
}

func createAudioDecoder(_ formatDescription: CMAudioFormatDescription) -> AudioDecoder? {
    guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
        print("Failed to get AudioStreamBasicDescription")
        return nil
    }
    let asbd = asbdPointer.pointee
    
    var inputFormat = AudioStreamBasicDescription(
          mSampleRate: asbd.mSampleRate,
          mFormatID: kAudioFormatMPEG4AAC,
          mFormatFlags: 0,
          mBytesPerPacket: 0,
          mFramesPerPacket: 1024, // AAC frame size
          mBytesPerFrame: 0,
          mChannelsPerFrame: asbd.mChannelsPerFrame,
          mBitsPerChannel: 0,
          mReserved: 0
    )

    var outputFormat = AudioStreamBasicDescription(
           mSampleRate: asbd.mSampleRate,
           mFormatID: kAudioFormatLinearPCM,
           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
           mBytesPerPacket: 4 * 2, // 4 bytes (Float32) * 2 channels
           mFramesPerPacket: 1,
           mBytesPerFrame: 4 * 2, // 4 bytes per frame * 2 channels
           mChannelsPerFrame: asbd.mChannelsPerFrame,
           mBitsPerChannel: 32, // Float32 (32-bit)
           mReserved: 0
    )

    var audioConverter: AudioConverterRef?
    let converterStatus = AudioConverterNew(&inputFormat, &outputFormat, &audioConverter)
    if converterStatus != noErr {
        print("Error initializing AudioConverter: \(converterStatus)")
        return nil
    }
    return AACDecoder(audioConverter: audioConverter!, inputFormat: inputFormat, outputFormat: outputFormat)
}

struct AACDecoder: AudioDecoder {
    private let audioConverter: AudioConverterRef
    private let inputFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    
    init(audioConverter: AudioConverterRef, inputFormat: AudioStreamBasicDescription, outputFormat: AudioStreamBasicDescription) {
        self.audioConverter = audioConverter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func decode(_ aacPackets: [Data], _ pts: Int64) -> (AVAudioPCMBuffer, Int64)? {
        guard let pcmBuffer = decodeAAC(
            aacPackets: aacPackets,
            audioConverter: self.audioConverter,
            inputFormat: self.inputFormat,
            outputFormat: self.outputFormat
        ) else {
            return nil
        }
        
        if let nonInterleavedBuffer = convertToNonInterleavedBuffer(from: pcmBuffer) {
            return (nonInterleavedBuffer, pts)
        } else {
            return nil
        }
    }

    func destroy() {
        AudioConverterDispose(self.audioConverter)
    }
}



class DecoderUserData {
    var aacPackets: [Data]
    var packetIndex: Int
    var numChannels: UInt32
    var framePerPacket: UInt32
    
    init(aacPackets: [Data], packetIndex: Int, numChannels: UInt32, framePerPacket: UInt32) {
        self.aacPackets = aacPackets
        self.packetIndex = packetIndex
        self.numChannels = numChannels
        self.framePerPacket = framePerPacket
    }
}


func decodeAAC(aacPackets: [Data], audioConverter: AudioConverterRef, inputFormat: AudioStreamBasicDescription, outputFormat: AudioStreamBasicDescription) -> AVAudioPCMBuffer? {
    let outputSampleCount: UInt32 = inputFormat.mFramesPerPacket // Adjust based on AAC frames
    let numChannels = UInt32(outputFormat.mChannelsPerFrame)
    
    var outFormat = outputFormat
    guard let audioFormat = AVAudioFormat(streamDescription: &outFormat) else {
        print("Error: Unable to create AVAudioFormat")
        return nil
    }
    
    let totalFrameCapacity = outputSampleCount * UInt32(aacPackets.count)
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: totalFrameCapacity) else {
        print("Error: Unable to create AVAudioPCMBuffer")
        return nil
    }
    pcmBuffer.frameLength = totalFrameCapacity
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: outputSampleCount) else {
        print("Error: Unable to create AVAudioPCMBuffer")
        return nil
    }
        
    let userData = DecoderUserData(aacPackets: aacPackets, packetIndex: 0, numChannels: numChannels, framePerPacket: inputFormat.mFramesPerPacket)
    let pcmData = buffer.audioBufferList.pointee.mBuffers.mData
    let pcmDataSize = 4 * numChannels * outputSampleCount  // float32 is 4 bytes
    var ioOutputDataPacketSize = UInt32(outputSampleCount)
    var outputData = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: numChannels,
            mDataByteSize: pcmDataSize,
            mData: pcmData // Will store the decoded PCM data
        )
    )
    
    var status = noErr
    var currentFrameOffset: UInt32 = 0
    while userData.packetIndex < aacPackets.count && status == noErr {
        status = AudioConverterFillComplexBuffer(
            audioConverter,
            inputDataProc,
            Unmanaged.passUnretained(userData as AnyObject).toOpaque(),
            &ioOutputDataPacketSize,
            &outputData,
            nil
        )
        
        if status == noErr {
            buffer.frameLength = ioOutputDataPacketSize
        } else {
            print("Error during conversion: \(status)")
            return nil
        }
        
        // Copy decoded PCM data into the persistent buffer
        if let sourceData = buffer.audioBufferList.pointee.mBuffers.mData {
            let destination = pcmBuffer.audioBufferList.pointee.mBuffers.mData! + Int(currentFrameOffset * 4 * numChannels)
            memcpy(destination, sourceData, Int(outputSampleCount * 4 * numChannels))
        }
        currentFrameOffset += ioOutputDataPacketSize
    }
    
    return pcmBuffer
}


// Input callback function to provide AAC data to the AudioConverter
func inputDataProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData = inUserData else {
        return kAudioConverterErr_InvalidInputSize
    }
    
    // Get the current packet index and list of AAC packets from inUserData
    let userData = Unmanaged<DecoderUserData>.fromOpaque(inUserData).takeUnretainedValue()
    guard userData.packetIndex < userData.aacPackets.count else {
        return kAudioConverterErr_InvalidInputSize
    }
    let currentPacket = userData.aacPackets[userData.packetIndex]
//    print("packet counter:", userData.packetIndex, currentPacket)
    
    // Fill in ioData with AAC data
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = userData.numChannels
    ioData.pointee.mBuffers.mDataByteSize = UInt32(currentPacket.count)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: (currentPacket as NSData).bytes)
    
    // We're providing one packet per call
    ioNumberDataPackets.pointee = 1
    
    // Provide packet descriptions if requested
    if let outDescriptions = outDataPacketDescription {
        outDescriptions.pointee = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        outDescriptions.pointee?.pointee.mStartOffset = 0
        outDescriptions.pointee?.pointee.mVariableFramesInPacket = userData.framePerPacket
        outDescriptions.pointee?.pointee.mDataByteSize = UInt32(currentPacket.count)
    }
    
    // Move to the next packet for the next call
    userData.packetIndex += 1
    
    return noErr
}


func convertToNonInterleavedBuffer(from interleavedBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    // Ensure the source buffer is interleaved
    guard interleavedBuffer.format.isInterleaved else {
        print("The source buffer is already non-interleaved.")
        return interleavedBuffer
    }

    // Extract essential properties
    let frameLength = interleavedBuffer.frameLength
    let sampleRate = interleavedBuffer.format.sampleRate
    let channelCount = interleavedBuffer.format.channelCount

    // Create a new AVAudioFormat with non-interleaved data
    guard let nonInterleavedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: sampleRate,
                                                   channels: channelCount,
                                                   interleaved: false) else {
        print("Error creating non-interleaved format.")
        return nil
    }

    // Create a new AVAudioPCMBuffer with the non-interleaved format
    guard let nonInterleavedBuffer = AVAudioPCMBuffer(pcmFormat: nonInterleavedFormat, frameCapacity: frameLength) else {
        print("Error creating non-interleaved buffer.")
        return nil
    }

    // Copy data from interleaved to non-interleaved format
    guard let interleavedChannelData = interleavedBuffer.floatChannelData else {
        print("No channel data in interleaved buffer.")
        return nil
    }
    
    guard let nonInterleavedChannelData = nonInterleavedBuffer.floatChannelData else {
        print("No channel data in non-interleaved buffer.")
        return nil
    }

    // Iterate through frames and separate data for each channel
    for frame in 0..<Int(frameLength) {
        for channel in 0..<Int(channelCount) {
            // Extract interleaved data and assign it to non-interleaved channels
            let interleavedIndex = frame * Int(channelCount) + channel
            nonInterleavedChannelData[channel][frame] = interleavedChannelData[0][interleavedIndex]
        }
    }

    // Set the frame length of the new buffer to match the original
    nonInterleavedBuffer.frameLength = frameLength

    return nonInterleavedBuffer
}
