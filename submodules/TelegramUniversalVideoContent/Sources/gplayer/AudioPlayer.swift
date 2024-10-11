import AVFoundation

func createAudioPlayer(_ audioFormat: AVAudioFormat, _ initBufferMs: UInt32 = 2000) -> AudioPlayer? {
    let audioEngine = AVAudioEngine()
    let audioPlayerNode = AVAudioPlayerNode()
    let bufferQueue = DispatchQueue(label: "gplayer.audioBufferQueue")
    
    audioEngine.attach(audioPlayerNode)
    let mainMixer = audioEngine.mainMixerNode
    audioEngine.connect(audioPlayerNode, to: mainMixer, format: audioFormat)

    do {
        try audioEngine.start()
        print("Audio engine started successfully")
    } catch {
        print("Error starting audio engine: \(error)")
        return nil
    }
    
    let samplesPerChunk: AVAudioFrameCount = UInt32(round(audioFormat.sampleRate / 50)) // split second of buffer in 50 chunks

    return AudioPlayer(audioEngine: audioEngine, audioPlayerNode: audioPlayerNode, bufferQueue: bufferQueue, samplesPerChunk: samplesPerChunk)
}

class AudioPlayer {
    private let audioEngine: AVAudioEngine
    private let audioPlayerNode: AVAudioPlayerNode
    private var bufferQueue: DispatchQueue
    private var _isPlaying: Bool = false
    private var initBuffer: [(AVAudioPCMBuffer, Int64)] = []
    private let samplesPerChunk: AVAudioFrameCount
    
    // for syncronising with frame drawing
    public var onPts: ((Int64) -> Void)?

    init(
        audioEngine: AVAudioEngine,
        audioPlayerNode: AVAudioPlayerNode,
        bufferQueue: DispatchQueue,
        samplesPerChunk: AVAudioFrameCount
    ) {
        self.audioEngine = audioEngine
        self.audioPlayerNode = audioPlayerNode
        self.bufferQueue = bufferQueue
        self.samplesPerChunk = samplesPerChunk
        print("> samplesPerChunk", samplesPerChunk)
    }

    private func start() {
        audioPlayerNode.play()
        print("Audio playback started")
        _isPlaying = true
        self.initBuffer.forEach { audioFrame in
            self.pushPCM(audioFrame.0, audioFrame.1)
        }
    }
    
    func isPlaying() -> Bool { return _isPlaying }

    func pushPCM(_ pcmBuffer: AVAudioPCMBuffer, _ pts: Int64) {
//        print("pushPCM", pts, pcmBuffer.frameLength)
        guard _isPlaying else {
            initBuffer.append((pcmBuffer, pts))
            // start playback after buffer has 2 seconds of data
//            if (initBuffer.count >= 2) {
            if (initBuffer.count >= 1) {
                self.start()
            }
            return
        }

        splitPCMBuffer(pcmBuffer, pts).forEach { audioFrame in
            self.pushToBufferQueue(audioFrame.0, audioFrame.1)
        }
    }
    
    private func pushToBufferQueue(_ pcmBuffer: AVAudioPCMBuffer, _ pts: Int64) {
        bufferQueue.async {
            self.audioPlayerNode.scheduleBuffer(pcmBuffer, completionHandler: {
                self.bufferQueue.async {
                    self.onPts?(pts)
                }
            })
        }
    }
    
    private func splitPCMBuffer(_ pcmBuffer: AVAudioPCMBuffer, _ pts: Int64) -> [(AVAudioPCMBuffer, Int64)] {
        let audioFormat = pcmBuffer.format
        let totalFrames = pcmBuffer.frameLength
        var currentFramePosition: AVAudioFramePosition = 0
        var currentPts = pts
        
        var smallerBuffers: [(AVAudioPCMBuffer, Int64)] = []

        while currentFramePosition < totalFrames {
            let chunkFrameLength = min(samplesPerChunk, totalFrames - AVAudioFrameCount(currentFramePosition))

            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: chunkFrameLength) else {
                print("Error creating smaller PCM buffer")
                break
            }

            // Copy the audio data from the original buffer to the new chunk buffer
            for channel in 0..<Int(audioFormat.channelCount) {
                let src = pcmBuffer.floatChannelData![channel]
                let dst = chunkBuffer.floatChannelData![channel]
                memcpy(dst, src.advanced(by: Int(currentFramePosition)), Int(chunkFrameLength) * MemoryLayout<Float>.size)
            }

            // Set the frame length of the chunk buffer
            chunkBuffer.frameLength = chunkFrameLength

            // Add the chunk buffer to the array
            smallerBuffers.append((chunkBuffer, currentPts))

            currentFramePosition += AVAudioFramePosition(chunkFrameLength)
            currentPts += Int64((Double(chunkFrameLength) / pcmBuffer.format.sampleRate) * 1000)
        }

        return smallerBuffers
    }

    func destroy() {
        audioPlayerNode.stop()
        audioEngine.stop()
        print("Audio engine and player stopped")
        _isPlaying = false
    }
}
