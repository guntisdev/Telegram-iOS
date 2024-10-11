import Foundation
import VideoToolbox


class GPlayer {
    private var _isPlaying = false
    private var isInitSegment = false
    private var frames: [CVPixelBuffer] = []
    private var fmp4Info: Fmp4Info?
    private var aacDecoder: AudioDecoder?
    private var h264Decoder: VideoDecoder?
    private var audioPlayer: AudioPlayer?
    private var bufferManager: BufferManager?
    
    // HACK for syncing before parsing out pts'es
    private var referenceTime: Int64 = -1
    private var referencePts: Int64 = 0
    
    private var manifestUrl: URL

    init(url: URL) {
        self.manifestUrl = url
//        let fetcher = Fetcher(onSuccess: onData, onError: onError)
//        fetcher.start(url: url)
    }
    
    public func setDrawableView(_ view: VideoCanvasView) {
        self.bufferManager = BufferManager(view)
    }
    
    private func onData(_ data: Data) {
        if (fmp4Info == nil) {
            fmp4Info = extractHeaders(from: data)
            if (fmp4Info!.video != nil) {
                let videoFormatDescription = createVideoFormatDescription(sps: fmp4Info!.video!.sps, pps: fmp4Info!.video!.pps)
                if videoFormatDescription != nil {
                    if self.bufferManager != nil { self.h264Decoder = createVideoDecoder(videoFormatDescription!, self.bufferManager!.pushFrame) }
                    print("video decoder:", self.h264Decoder != nil)
                }
            }
            if fmp4Info!.audio != nil {
                let audioFormatDescription = createAudioFormatDescription(
                    sampleRate: fmp4Info!.audio!.sampleRate,
                    channelCount: fmp4Info!.audio!.channelCount,
                    audioObjectType: fmp4Info!.audio!.audioObjectType,
                    audioSpecificConfig: fmp4Info!.audio!.audioSpecificConfig
                )
                if audioFormatDescription != nil {
                    self.aacDecoder = createAudioDecoder(audioFormatDescription!)
                    print("audio decoder:", self.aacDecoder != nil)
                }
            }
        } else {
            
            if (fmp4Info!.audio != nil) {
                let aacPackets = extractRawAudio(from: data, audioTrackId: fmp4Info!.audio!.trackId)
                print("audio packets:", aacPackets.1.count, aacPackets.1[0])
                
                if let pcmBuffer = self.aacDecoder!.decode(aacPackets.1, aacPackets.0) {
                    if audioPlayer == nil {
                        audioPlayer = createAudioPlayer(pcmBuffer.0.format)
                        audioPlayer!.onPts = { nextPts in
                            let now = Int64(Date().timeIntervalSince1970 * 1_000)
                            if self.referenceTime == -1 {
                                self.referenceTime = now
                            }
                            let currentFps = self.referencePts + now - self.referenceTime
//                            if self.bufferManager != nil { self.bufferManager?.draw(nextPts) }
                            if self.bufferManager != nil { self.bufferManager?.draw(currentFps) }
                        }
                    }
                    print("before push", pcmBuffer.0.frameLength)
                    audioPlayer!.pushPCM(pcmBuffer.0, pcmBuffer.1)
                } else { print("No pcm buffer created") }
            } else { print("No audio headers parsed") }
            
            if (fmp4Info!.video != nil) {
                let naluArr = extractRawVideo(from: data, videoTrackId: fmp4Info!.video!.trackId)
                print("naluArr", naluArr.count)
                let sampleBuffers = handleNalu(naluArr: naluArr, videoFormatDescription:  h264Decoder!.getFormatDescription())
                
                if self.h264Decoder != nil {
                    for sampleBuffer in sampleBuffers {
                        self.h264Decoder!.decode(sampleBuffer)
                    }
                }
            } else { print("No video headers parsed") }
        }
    }
    
    private func onError(_ error: Error) {
        print(error)
    }
    
    func setManifestUrl(_ url: URL) {
        print("set new manifest url", url)
        self.manifestUrl = url
    }

    func play() {
        _isPlaying = true
        print("GPlayer started playing")
       
        let fetcher = Fetcher(onSuccess: onData, onError: onError)
        fetcher.start(url: self.manifestUrl)
    }

    func pause() {
        _isPlaying = false
        print("GPlayer paused")
        // Implement actual pause logic here
    }

    func isPlaying() -> Bool {
        return _isPlaying
    }
}
