import Foundation

struct FetchMasterPlaylist {
    static func get(_ url: URL, completion: @escaping (Result<[(URL, String, Int)], Error>) -> Void) {
        fetch(url) { result in
            switch result {
            case .success(let data):
                if let masterResult = self.parseMasterPlaylist(data, url) {
                    completion(.success(masterResult))
                } else {
                    completion(.failure(MasterPlaylistError.failedToParseMasterPlaylist))
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
                let error = NSError(domain: "FetchMasterPlaylistError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                completion(.failure(error))
                return
            }
            
            if let data = data {
                completion(.success(data))
            } else {
                let error = NSError(domain: "FetchMasterPlaylistError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                completion(.failure(error))
            }
        }
        task.resume()
    }
    
    private static func parseMasterPlaylist(_ data: Data, _ masterPlaylistUrl: URL) -> [(URL, String, Int)]? {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        var variants: [(URL, String, Int)] = []
        var currentBandwidth: Int = 0
        var currentNameOrResolution: String = ""
        
        for (_, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = line.components(separatedBy: ":")[1].components(separatedBy: ",")
                for attribute in attributes {
                    let keyValue = attribute.components(separatedBy: "=")
                    if keyValue.count == 2 {
                        let key = keyValue[0].trimmingCharacters(in: .whitespaces)
                        let value = keyValue[1].trimmingCharacters(in: .whitespaces)
                        
                        if key == "BANDWIDTH" {
                            currentBandwidth = Int(value) ?? 0
                        } else if key == "NAME" {
                            currentNameOrResolution = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        } else if key == "RESOLUTION" {
                            currentNameOrResolution = value
                        }
                    }
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                // Construct a URL using the master playlist's base URL but replacing only the last path component
                if var finalUrlComponents = URLComponents(url: masterPlaylistUrl, resolvingAgainstBaseURL: false) {
                    finalUrlComponents.path = (finalUrlComponents.path as NSString).deletingLastPathComponent.appending("/\(line)")
                    if let finalUrl = finalUrlComponents.url {
                        variants.append((finalUrl, currentNameOrResolution, currentBandwidth))
                    }
                }
            }
        }
        
        return variants
    }
    
    enum MasterPlaylistError: Error {
        case failedToParseMasterPlaylist
    }
}
