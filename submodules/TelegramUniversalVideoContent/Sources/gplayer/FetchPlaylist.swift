import Foundation

struct RangeUrl {
    let url: URL
    let byteRange: String?
    init(_ url: URL, _ byteRange: String? = nil) {
        self.url = url
        self.byteRange = byteRange
    }
}

struct FetchPlaylist {
    static func get(_ url: URL,completion: @escaping (Result<(RangeUrl, [RangeUrl]), Error>) -> Void) {
        fetch(url) { result in
            switch result {
            case .success(let data):
                if let masterResult = self.parseMediaPlaylist(data, url) {
                    completion(.success(masterResult))
                } else {
                    completion(.failure(PlaylistError.failedToParseMediaPlaylist))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private static func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "FetchMediaPlaylistError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                completion(.failure(error))
                return
            }
            
            if let data = data {
                completion(.success(data))
            } else {
                let error = NSError(domain: "FetchMediaPlaylistError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                completion(.failure(error))
            }
        }
        task.resume()
    }
    
    private static func parseMediaPlaylist(_ data: Data, _ mediaPlaylistUrl: URL) -> (RangeUrl, [RangeUrl])? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        if content.contains("#EXT-X-BYTERANGE") {
            // Playlist with byte ranges - call the specialized parser for second format
            return parseByteRangePlaylist(data, mediaPlaylistUrl)
        } else if content.contains("#EXT-X-MAP:URI=") {
            // Playlist with complete media files - call the parser for the first format
            return parseSegmentMediaPlaylist(data, mediaPlaylistUrl)
        } else {
            return nil
        }
    }
    
    private static func parseSegmentMediaPlaylist(_ data: Data, _ mediaPlaylistUrl: URL) -> (RangeUrl, [RangeUrl])? {
        guard let content = String(data: data, encoding: .utf8) else { return (RangeUrl(mediaPlaylistUrl), []) }

        var mediaSegments: [RangeUrl] = []
        let lines = content.components(separatedBy: .newlines)
        var initializationSegmentURL: URL?
        
        for (_, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-MAP:URI=") {
                let uriString = line.components(separatedBy: "\"")[1]
                if var initSegmentUrl = URLComponents(url: mediaPlaylistUrl, resolvingAgainstBaseURL: false) {
                    initSegmentUrl.path = (initSegmentUrl.path as NSString).deletingLastPathComponent.appending("/\(uriString)")
                    print(initSegmentUrl, uriString)
                    initializationSegmentURL = initSegmentUrl.url
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                if var segmentURL = URLComponents(url: mediaPlaylistUrl, resolvingAgainstBaseURL: false) {
                    segmentURL.path = (segmentURL.path as NSString).deletingLastPathComponent.appending("/\(line)")
                    if let finalUrl = segmentURL.url {
                        mediaSegments.append(RangeUrl(finalUrl))
                    }
                }
            }
        }
        
        return (RangeUrl(initializationSegmentURL!), mediaSegments)
    }
    
    private static func parseByteRangePlaylist(_ data: Data, _ mediaPlaylistUrl: URL) -> (RangeUrl, [RangeUrl])? {
        guard let content = String(data: data, encoding: .utf8) else { return (RangeUrl(mediaPlaylistUrl), []) }

        var mediaSegments: [RangeUrl] = []
        let lines = content.components(separatedBy: .newlines)
        var initRangeUrl: RangeUrl?
        var currentByteRange: String?

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-MAP:URI=") {
                // Extract the URI and Byte Range from the EXT-X-MAP line
                if let uriRange = line.range(of: "URI=\""), let endQuote = line.range(of: "\"", range: uriRange.upperBound..<line.endIndex) {
                    let uriString = String(line[uriRange.upperBound..<endQuote.lowerBound])
                    let initUrl = self.resolveURL(mediaPlaylistUrl, uriString)!
                    
                    if let byteRangeIndex = line.range(of: "BYTERANGE=") {
                        let byteRange = String(line[byteRangeIndex.upperBound...])
                            .components(separatedBy: ",")
                            .first?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        initRangeUrl = RangeUrl(initUrl, self.parseByteRange(byteRange!))
                    } else {
                        initRangeUrl = RangeUrl(initUrl, nil)
                    }
                }
            } else if line.hasPrefix("#EXTINF:") {
                // Check if there's a byte range on the next line
                if index + 1 < lines.count {
                    let nextLine = lines[index + 1]
                    if nextLine.hasPrefix("#EXT-X-BYTERANGE:") {
                        let br = nextLine.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                        currentByteRange = self.parseByteRange(br!)
                    }
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                // Process the media segment line, which contains the file name
                let segmentUrl = self.resolveURL(mediaPlaylistUrl, line)
                let segment = RangeUrl(segmentUrl!, currentByteRange)
                mediaSegments.append(segment)
                currentByteRange = nil  // Reset the byte range for the next segment
            }
        }

        if let initUrl = initRangeUrl {
            return (initUrl, mediaSegments)
        } else {
            print("Failed to parse media playlist")
            return nil
        }
    }
    
    private static func resolveURL(_ baseURL: URL, _ relativeOrAbsolutePath: String) -> URL? {
        // absolute url
        if let absoluteURL = URL(string: relativeOrAbsolutePath), absoluteURL.scheme != nil {
            return absoluteURL
        }
        
        // relative url
        var modifiedBaseURL = baseURL
        modifiedBaseURL.deleteLastPathComponent()
        return modifiedBaseURL.appendingPathComponent(relativeOrAbsolutePath)
    }
    
    private static func parseByteRange(_ input: String) -> String? {
        let parts = input.split(separator: "@")
        if parts.count == 2, let length = Int(parts[0]), let start = Int(parts[1]) {
            return "\(start)-\(start + length - 1)"
        } else {
            return nil
        }
    }
    
    enum PlaylistError: Error {
        case failedToParseMediaPlaylist
    }
}



/*
 #EXTM3U
 #EXT-X-TARGETDURATION:6
 #EXT-X-VERSION:6
 #EXT-X-MEDIA-SEQUENCE:1
 #EXT-X-INDEPENDENT-SEGMENTS
 #EXT-X-MAP:URI="partfile5149927939822847496.mp4",BYTERANGE="1453@0"
 #EXTINF:6
 #EXT-X-BYTERANGE:361186@1705
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:350041@362891
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:458366@712932
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:399162@1171298
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:408644@1570460
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:229137@1979104
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:473309@2208241
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:259979@2681550
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:531056@2941529
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:289461@3472585
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:280944@3762046
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:281760@4042990
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:373443@4324750
 partfile5149927939822847496.mp4
 #EXTINF:4
 #EXT-X-BYTERANGE:130096@4698193
 partfile5149927939822847496.mp4
 #EXTINF:6
 #EXT-X-BYTERANGE:232414@4828289
 partfile5149927939822847496.mp4
 #EXTINF:1.79167
 #EXT-X-BYTERANGE:65801@5060703
 partfile5149927939822847496.mp4

 #EXT-X-ENDLIST
 */
