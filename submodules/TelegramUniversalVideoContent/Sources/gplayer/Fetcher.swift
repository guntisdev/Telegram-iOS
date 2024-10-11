import Foundation
import VideoToolbox

class Fetcher {
    typealias DataCallback = (Data) -> Void
    typealias ErrorCallback = (Error) -> Void
    
    private var onSuccess: DataCallback
    private var onError: ErrorCallback
    
    private var isInitSegment = false
    private var doneSegmentUrls: [RangeUrl] = []
    private var nextSegmentUrls: [RangeUrl] = []
    private var mediaPlaylistUrl: URL?
    private var fetchingSegmentUrl: RangeUrl?
    //    private var loopCounter = 0
    
    init(onSuccess: @escaping DataCallback, onError: @escaping ErrorCallback) {
        self.onSuccess = onSuccess
        self.onError = onError
    }
    
    func start(url: URL) {
        FetchMasterPlaylist.get(url) { result in
            switch result {
            case .success(let masterPlaylist):
                print("--==masterPlaylist--==")
                print(masterPlaylist)
                self.mediaPlaylistUrl = masterPlaylist[2].0 // quality
//                print(">>", self.mediaPlaylistUrl!)
                self.fetchMediaPlaylistLoop()
            case .failure(let error):
                self.onError(error)
            }
        }
    }
    
    private func fetchMediaPlaylistLoop() {
        // TODO loop counter and exit only for testing purposes
        //        if self.loopCounter >= 100 { return }
        //        print("loop:", self.loopCounter)
        //        self.loopCounter += 1
        
        guard let url = self.mediaPlaylistUrl else {
            return self.onError(MediaPlaylistError.notFoundMediaPlaylist)
        }
        
        FetchPlaylist.get(url){ result in
            switch result {
                case .success(let (initSegmentUrl, mediaSegments)):
                    print("--==mediaPlaylist--==")
//                    print(initSegmentUrl, mediaSegments)
                    self.pushSegmentUrls(mediaSegments)
                    if (!self.isInitSegment) {
                        self.fetchInitSegment(initSegmentUrl)
                        return
                    } else {
                        self.fetchMediaSegment()
                        // TODO uncomment forever loop
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) {
                            self.fetchMediaPlaylistLoop()
                        }
                    }
                case .failure(let error):
                    self.onError(error)
            }
        }
    }
    
    private func fetchInitSegment(_ initSegmentUrl: RangeUrl) {
        fetch(initSegmentUrl) { result in
            switch result {
            case .success(let initSegment):
                self.isInitSegment = true
                print("Init segment: \(initSegment.count) bytes")
                self.onSuccess(initSegment)
                self.fetchMediaPlaylistLoop()
            case .failure(let error):
                self.onError(error)
            }
        }
    }
        
    func fetchMediaSegment() {
        if (self.fetchingSegmentUrl != nil) {
            return
        }
        
        guard let url = self.nextSegmentUrls.first else {
            return
        }
        
        self.fetchingSegmentUrl = url
        
        fetch(url){ result in
            switch result {
            case .success(let mediaSegment):
                print("Media segment: \(mediaSegment.count) bytes")
                self.onSuccess(mediaSegment)
                self.setSegmentFetched(url)
                self.fetchMediaSegment()
            case .failure(let error):
                self.onError(error)
            }
        }
    }
        
    func fetch(_ rangeUrl: RangeUrl, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: rangeUrl.url)
        if rangeUrl.byteRange != nil {
            request.setValue("bytes=\(rangeUrl.byteRange!)", forHTTPHeaderField: "Range")
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "FetchSegmentError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                completion(.failure(error))
                return
            }
            
            if let data = data {
                completion(.success(data))
            } else {
                let error = NSError(domain: "FetchSegmentError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                completion(.failure(error))
            }
        }
        task.resume()
    }
        
    func pushSegmentUrls(_ rangeUrls: [RangeUrl]) {
        rangeUrls.forEach { rangeUrl in
            if doneSegmentUrls.contains(where: { $0.url == rangeUrl.url && $0.byteRange == rangeUrl.byteRange })
                || nextSegmentUrls.contains(where: { $0.url == rangeUrl.url && $0.byteRange == rangeUrl.byteRange }) {
                return
            } else {
                nextSegmentUrls.append(rangeUrl)
            }
        }
    }
        
    func setSegmentFetched(_ url: RangeUrl) {
        self.fetchingSegmentUrl = nil
        nextSegmentUrls.removeAll { $0.url == url.url }
        doneSegmentUrls.append(url)
        if doneSegmentUrls.count > 10 {
            doneSegmentUrls.removeFirst()
        }
    }
    
    enum MediaPlaylistError: Error {
        case notFoundMediaPlaylist
    }
}
