import Foundation

typealias Atom = (size: UInt32, name: String, content: Data)

struct Fmp4Info {
    var video: VideoInfo?
    var audio: AudioInfo?
    
    struct VideoInfo {
        let trackId: Int32
        let sps: Data
        let pps: Data
    }
    
    struct AudioInfo {
        let trackId: Int32
        let sampleRate: Float64
        let channelCount: UInt32
        let audioObjectType: UInt32
        let audioSpecificConfig: [UInt8]
    }
    
    init() {}
    
    mutating func setVideoInfo(trackId: Int32, sps: Data, pps: Data) {
        self.video = VideoInfo(trackId: trackId, sps: sps, pps: pps)
    }
    
    mutating func setAudioInfo(trackId: Int32, sampleRate: Float64, channelCount: UInt32, audioObjectType: UInt32, audioSpecificConfig: [UInt8]) {
        self.audio = AudioInfo(trackId: trackId, sampleRate: sampleRate, channelCount: channelCount, audioObjectType: audioObjectType, audioSpecificConfig: audioSpecificConfig)
    }
}

func extractHeaders(from data: Data) -> Fmp4Info {
    var fmp4Info = Fmp4Info()
    let moov = extractAtoms(from: data).first{$0.1 == "moov"}!
    let trakAtoms = extractAtoms(from: moov.2).filter{ $0.1 == "trak"}
    for trak in trakAtoms {
        let hdlr = findAtom(in: trak.2, path: ["mdia", "hdlr"])!
        let trackType = getTrackType(hdlr: hdlr)
        let tkhd = findAtom(in: trak.2, path: ["tkhd"])!
        let trackId = getTrackIdTKHD(tkhd: tkhd)
        
        let stbl = findAtom(in: trak.2, path: ["mdia", "minf", "stbl"])!
        let stsd = findAtom(in: stbl.2, path: ["stsd"])!
        let codecAtom = extractAtoms(from: stsd.2.subdata(in: 8..<stsd.2.count)).first!
        
        if trackType == TrackType.vide {
            let codedWidth = toInt(bytes: codecAtom.2.subdata(in: 24..<26))
            let codedHeight = toInt(bytes: codecAtom.2.subdata(in: 26..<28))
            print("video: \(codedWidth)x\(codedHeight)px")
            
            let avccBuff = codecAtom.2.subdata(in: 78..<codecAtom.2.count ) // avcC atom offset
            let avcc = extractAtoms(from: avccBuff).first!
            var avccOffset = 6
            let spsLength = toInt(bytes: avcc.2.subdata(in: avccOffset..<avccOffset+2))
            avccOffset += 2
            let sps = avcc.2.subdata(in: avccOffset..<avccOffset+spsLength)
            avccOffset += spsLength
            avccOffset += 1
            let ppsLength = toInt(bytes: avcc.2.subdata(in: avccOffset..<avccOffset+2))
            avccOffset += 2
            let pps = avcc.2.subdata(in: avccOffset..<avccOffset + ppsLength)
            
//            if (sps != nil && pps != nil) {
                fmp4Info.setVideoInfo(trackId: trackId, sps: sps, pps: pps)
//            }
            /*
                Read first byte from sps and pps
                last 5 bits of the first byte are 7, the NALU is an SPS
                last 5 bits of the first byte are 8, the NALU is an PPS
                103 = 0x67 = last 5 bits 7
                104 = 0x68 = last 5 bits 8
            */
        }
        else if trackType == TrackType.soun {
//            print(codecAtom.name) // mp4a
            let esdsBuff = codecAtom.2.subdata(in: 28..<codecAtom.2.count) // esds atom offset
            let esds = extractAtoms(from: esdsBuff).first!
            let channelCount = UInt32(toInt(bytes: codecAtom.2.subdata(in: 16..<18)))
            let sampleRate = Float64(toInt(bytes: codecAtom.2.subdata(in: 24..<26)))
            
            let audioSpecificConfig = extractAudioSpecificConfig(from: esds.2)
            
//            if (channelCount != nil && sampleRate != nil && audioSpecificConfig != nil) {
                print("audio: \(channelCount)ch \(sampleRate)rate")
                fmp4Info.setAudioInfo(
                    trackId: trackId,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    audioObjectType: 2,
                    // esds https://github.com/mono/taglib-sharp/issues/146
                    audioSpecificConfig: audioSpecificConfig!
                )
//            }
        }
    }
    
    return fmp4Info
}

func extractAudioSpecificConfig(from esdsData: Data) -> [UInt8]? {
    let specConfig = esdsData.subdata(in: 4..<esdsData.count)
    return Array(specConfig)
}


func getTrackIdTKHD(tkhd: Atom) -> Int32 {
    let version = tkhd.content[0]
    let trackId: Int32
    if version == 0 {
        trackId = tkhd.content.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: Int32.self) }
    } else {
        trackId = tkhd.content.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: Int32.self) }
    }
    return trackId.bigEndian
}

enum TrackType: String {
    case soun = "soun"
    case vide = "vide"
}

func getTrackType(hdlr: Atom) -> TrackType {
    let subdata = hdlr.content.subdata(in: 8..<12)
    let typeString = toString(bytes: (subdata))
    return TrackType(rawValue: typeString) ?? .vide // Default to video if unknown
}

func toString(bytes: Data) -> String {
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

func toInt(bytes: Data) -> Int {
    return bytes.reduce(0) { $0 * 256 + Int($1) }
}

struct RawExtractInfo {
    var offset: Int
    var chunkSizes: [Int]
}

func extractRawAudio(from data: Data, audioTrackId: Int32) -> (Int64, [Data]) {
    print("extract raw audio", audioTrackId, data.count)
    var audioExtractInfo: RawExtractInfo?
//    var firstPts: Int64?
    let firstPts: Int64 = 0
    var rawData: [Data] = []
    for atom in extractAtoms(from: data) {
        // Looks like there could be also one moof and one mdat with audio and video together
        print(atom.1, atom.0)
        if atom.1 == "moof" {
            /* moof
                   mfhd
                   traf: tfhd, tfdt, trun
            */
            audioExtractInfo = nil
            extractAtoms(from: atom.2)
                .filter { $0.1 == "traf" }
                .map { traf in
                    let tfhd = findAtom(in: traf.2, path: ["tfhd"])!
                    let trackId = getTrackId(tfhd)
                    return (trackId, traf)
                }
                .filter { $0.0 == audioTrackId } // filter audio track trafs
                .forEach { (trackId, traf) in
                    guard let tfdt = extractAtoms(from: traf.2).filter({ $0.1 == "tfdt"}).first else {
                        return
                    }
                    let pts = getPts(tfdt)
                    print("AUDIO PTS", pts)
                    
                    guard let trun = extractAtoms(from: traf.2).filter({ $0.1 == "trun"}).first else {
                        return
                    }
                    let audioOffset = toInt(bytes: trun.2.subdata(in: 8..<12))
//                    let chunkCount = toInt(bytes: trun.2.subdata(in: 0..<4))
                    let trunChunksData = splitDataIntoChunks(trun.2.subdata(in: 12..<trun.2.count))
                    let chunkSizes = trunChunksData.map({ toInt(bytes: $0) })
                    let sum = chunkSizes.reduce(0, +)
                    
                    print(pts, chunkSizes.count, audioOffset, sum, Array(trun.2.subdata(in: 0..<12)))
                    
                    audioExtractInfo = RawExtractInfo(offset: audioOffset, chunkSizes: chunkSizes)
                }
            
        } else if atom.1 == "mdat" && audioExtractInfo != nil {
            var offset = audioExtractInfo!.offset
            // IMPORTANT offset is given from media segment start, not from mdat start
            for chunkSize in audioExtractInfo!.chunkSizes {
                let audioData = data.subdata(in: offset..<offset+chunkSize)
                offset += chunkSize
                rawData.append(audioData)
            }
        }
    }
    
    return (firstPts, rawData)
}


func extractRawVideo(from data: Data, videoTrackId: Int32) -> [(Int, [Data])] {
    print("extractRawVideo", videoTrackId, data.count)
    var videoExtractInfo: RawExtractInfo?
    var currentPts = 0
    var naluArr: [(Int, [Data])] = []
    for atom in extractAtoms(from: data) {
        if atom.1 == "moof" {
            extractAtoms(from: atom.2)
                .filter { $0.1 == "traf" }
                .map { traf in
                    let tfhd = findAtom(in: traf.2, path: ["tfhd"])!
                    let trackId = getTrackId(tfhd)
//                    print("tfhd", Array(tfhd.2))
                    return (trackId, traf)
                }
                .filter { $0.0 == videoTrackId } // filter video track trafs
                .forEach { (trackId, traf) in
                    guard let tfdt = extractAtoms(from: traf.2).filter({ $0.1 == "tfdt"}).first else {
                        return
                    }
                    print("VIDEO PTS", getPts(tfdt))
                    
                    guard let trun = extractAtoms(from: traf.2).filter({ $0.1 == "trun"}).first else {
                        return
                    }
                    
                   
                    let chunkCount = toInt(bytes: trun.2.subdata(in: 4..<8))
                    let trunChunksData = splitDataIntoChunks(trun.2.subdata(in: 12..<trun.2.count), 12)
                    let chunkSizes = trunChunksData.map({ sizeData in
                        return toInt(bytes: sizeData.subdata(in: 0..<4))
                    })
                    let sum = chunkSizes.reduce(0, +)
                    
                    print(videoTrackId, chunkCount, chunkSizes.count, sum)
                    videoExtractInfo = RawExtractInfo(offset: 0, chunkSizes: chunkSizes)

                }
            
        } else if atom.1 == "mdat" && videoExtractInfo != nil {
            var offset = videoExtractInfo!.offset
            // IMPORTANT offset is given from mdat content start
            for chunkSize in videoExtractInfo!.chunkSizes {
                let videoData = atom.2.subdata(in: offset..<offset+chunkSize)
                offset += chunkSize
                naluArr.append((currentPts, extractNalu(from: videoData)))
                currentPts += 42 // hardcoded for now
            }
        }
    }

    return naluArr
}

func extractNalu(from data: Data) -> [Data] {
    var naluArr: [Data] = []
    var offset = 0
    
    while offset < data.count {
        let naluSize = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        // Ensure that the remaining data has enough bytes for the NALU
        let naluEnd = offset + 4 + Int(naluSize)
        guard naluEnd <= data.count else {
            print("NALU size exceeds available data")
            break
        }
        
        // Extract the NALU data and append to the array
        let nalu = data.subdata(in: offset..<naluEnd)
        
        /*
            first 4 bytes are size in big endian
            5th byte is nalu type
            101 = 0x65 = IDR (Instantaneous Decoding Refresh) frame
            65 = 0x41 = non-IDR (Instantaneous Decoding Refresh) frame
        */
//        print(nalu[0], nalu[1], nalu[2], nalu[3], nalu[4])
        
        naluArr.append(nalu)
        offset = naluEnd
    }
    
    return naluArr
}

func getTrackId(_ tfhdAtom: Atom) -> Int {
    return tfhdAtom.2.count > 16 ? Int(tfhdAtom.2[16]) :  Int(tfhdAtom.2[7])
}

func getPts(_ tfdtAtom: Atom) -> Int {
    let range = tfdtAtom.2.count > 8 ? 4..<12 : 4..<8
    let ptsData = tfdtAtom.2.subdata(in: range)
    return toInt(bytes: ptsData)
}


func findAtom(in data: Data, path: [String]) -> Atom? {
    var currentAtom: Atom?

    for atomName in path {
        let currentData = currentAtom?.2 ?? data
        let extractedAtoms = extractAtoms(from: currentData)

        if let foundAtom = extractedAtoms.first(where: { $0.name == atomName }) {
            currentAtom = foundAtom
        } else {
            // Atom not found at this level, return nil
            return nil
        }
    }
    
    return currentAtom
}

func extractAtoms(from data: Data) -> [Atom] {
    var offset = 0
    var atoms: [Atom] = []
    
    while offset < data.count {
        // Ensure there is enough data for size (4 bytes) and name (4 bytes)
        guard offset + 8 <= data.count else {
            print("Not enough data to parse atom size and name.")
            break
        }
        
        // Read the atom size (4 bytes, big-endian)
        let sizeRange = offset..<offset+4
        let atomSize = data.subdata(in: sizeRange).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Read the atom name (4 bytes)
        let nameRange = offset+4..<offset+8
        let atomName = String(data: data.subdata(in: nameRange), encoding: .utf8) ?? "Unknown"
        
        // Calculate the atom's content range (starting after the first 8 bytes for size + name)
        let contentStart = offset + 8
        let contentEnd = offset + Int(atomSize)
        
        // Ensure contentEnd does not exceed data count
        guard contentEnd <= data.count else {
            print("Atom size exceeds available data.")
            break
        }
        
        // Extract the atom content
        let content = data.subdata(in: contentStart..<contentEnd)
        
        // Append the parsed atom to the array
        atoms.append((size: atomSize, name: atomName, content: content))
        
        // Move the offset forward by the size of the current atom
        offset += Int(atomSize)
    }
    
    return atoms
}

func splitDataIntoChunks(_ data: Data, _ chunkSize: Int = 4) -> [Data] {
    var chunks: [Data] = []
    var startIndex = 0

    while startIndex < data.count {
        let endIndex = min(startIndex + chunkSize, data.count)
        let chunk = data.subdata(in: startIndex..<endIndex)
        chunks.append(chunk)
        startIndex += chunkSize
    }

    return chunks
}
