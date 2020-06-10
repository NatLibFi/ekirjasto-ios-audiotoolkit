import AVFoundation

let ODTaskCompleteNotification = NSNotification.Name(rawValue: "OverdriveDownloadTaskCompleteNotification")

final class OverdriveDownloadTask: DownloadTask {
    public enum AssetResult {
        /// The file exists at the given URL.
        case saved(URL)
        /// The file is missing at the given URL.
        case missing(URL)
        /// Could not create a valid URL to check.
        case unknown
    }

    private let DownloadTaskTimeoutValue = 60.0

    weak var delegate: DownloadTaskDelegate?

    /// Progress should be set to 1 if the file already exists.
    var downloadProgress: Float = 0 {
        didSet {
            self.delegate?.downloadTaskDidUpdateDownloadPercentage(self)
        }
    }

    let key: String
    let url: URL
    let urlMediaType: OverdriveSpineElementMediaType

    public init(spineElement: OverdriveSpineElement) {
        self.key = spineElement.key
        self.url = spineElement.url
        self.urlMediaType = spineElement.mediaType
    }
    
    func fetch() {
        switch self.assetFileStatus() {
        case .saved(_):
            downloadProgress = 1.0
            self.delegate?.downloadTaskReadyForPlayback(self)
        case .missing(let missingAssetURL):
            switch urlMediaType {
            case .audioMP3:
                self.downloadAsset(fromRemoteURL: self.url, toLocalDirectory: missingAssetURL)
            }
        case .unknown:
            self.delegate?.downloadTaskFailed(self, withError: nil)
        }
    }

    func delete() {
        switch self.assetFileStatus() {
        case .saved(let url):
            do {
                try FileManager.default.removeItem(at: url)
                self.delegate?.downloadTaskDidDeleteAsset(self)
            } catch {
                ATLog(.error, "FileManager removeItem error:\n\(error)")
            }
        case .missing(_):
            ATLog(.debug, "No file located at directory to delete.")
        case .unknown:
            ATLog(.error, "Invalid file directory from command")
        }
    }

    public func assetFileStatus() -> AssetResult {
        guard let localAssetURL = localDirectory() else {
            return AssetResult.unknown
        }
        if FileManager.default.fileExists(atPath: localAssetURL.path) {
            return AssetResult.saved(localAssetURL)
        } else {
            return AssetResult.missing(localAssetURL)
        }
    }

    /// Directory of the downloaded file.
    private func localDirectory() -> URL? {
        let fileManager = FileManager.default
        let cacheDirectories = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let cacheDirectory = cacheDirectories.first else {
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        guard let filename = hash(self.key) else {
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        return cacheDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
    }
    
    private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL)
    {
        let config = URLSessionConfiguration.ephemeral
        let delegate = OverdriveDownloadTaskURLSessionDelegate(downloadTask: self,
                                                               delegate: self.delegate,
                                                               finalDirectory: finalURL)
        let session = URLSession(configuration: config,
                                 delegate: delegate,
                                 delegateQueue: nil)
        
        let request = URLRequest(url: remoteURL,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: DownloadTaskTimeoutValue)
        
        let task = session.downloadTask(with: request)
        task.resume()
    }

    private func hash(_ key: String) -> String? {
        guard let hash = NYPLStringAdditions.sha256forString(key) else {
            return nil
        }
        return hash
    }
}

final class OverdriveDownloadTaskURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {

    private let downloadTask: OverdriveDownloadTask
    private let delegate: DownloadTaskDelegate?
    private let finalURL: URL

    /// Each Spine Element's Download Task has a URLSession delegate.
    /// If the player ever evolves to support concurrent requests, there
    /// should just be one delegate objects that keeps track of them all.
    /// This is only for the actual audio file download.
    ///
    /// - Parameters:
    ///   - downloadTask: The corresponding download task for the URLSession.
    ///   - delegate: The DownloadTaskDelegate, to forward download progress
    ///   - finalDirectory: Final directory to move the asset to
    required init(downloadTask: OverdriveDownloadTask,
                  delegate: DownloadTaskDelegate?,
                  finalDirectory: URL) {
        self.downloadTask = downloadTask
        self.delegate = delegate
        self.finalURL = finalDirectory
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL)
    {
        guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
            ATLog(.error, "Response could not be cast to HTTPURLResponse: \(self.downloadTask.key)")
            self.delegate?.downloadTaskFailed(self.downloadTask, withError: nil)
            return
        }

        if (httpResponse.statusCode == 200) {
            verifyDownloadAndMove(from: location, to: self.finalURL) { (success) in
                if success {
                    ATLog(.debug, "File successfully downloaded and moved to: \(self.finalURL)")
                    if FileManager.default.fileExists(atPath: location.path) {
                        do {
                            try FileManager.default.removeItem(at: location)
                        } catch {
                            ATLog(.error, "Could not remove original downloaded file at \(location.absoluteString) Error: \(error)")
                        }
                    }
                    self.downloadTask.downloadProgress = 1.0
                    self.delegate?.downloadTaskReadyForPlayback(self.downloadTask)
                    NotificationCenter.default.post(name: ODTaskCompleteNotification, object: self.downloadTask)
                } else {
                    self.downloadTask.downloadProgress = 0.0
                    self.delegate?.downloadTaskFailed(self.downloadTask, withError: nil)
                }
            }
        } else {
            ATLog(.error, "Download Task failed with server response: \n\(httpResponse.description)")
            self.downloadTask.downloadProgress = 0.0
            self.delegate?.downloadTaskFailed(self.downloadTask, withError: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        ATLog(.debug, "urlSession:task:didCompleteWithError: curl representation \(task.originalRequest?.curlString ?? "")")
        guard let error = error else {
            ATLog(.debug, "urlSession:task:didCompleteWithError: no error.")
            return
        }

        ATLog(.error, "No file URL or response from download task: \(self.downloadTask.key).", error: error)

        if let code = (error as NSError?)?.code {
            switch code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost:
                let networkLossError = NSError(domain: OverdrivePlayerDomain, code: 3, userInfo: nil)
                self.delegate?.downloadTaskFailed(self.downloadTask, withError: networkLossError)
                return
            default:
                break
            }
        }

        self.delegate?.downloadTaskFailed(self.downloadTask, withError: error as NSError?)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64)
    {
        if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) ||
            totalBytesExpectedToWrite == 0 {
            self.downloadTask.downloadProgress = 0.0
        }

        if totalBytesWritten >= totalBytesExpectedToWrite {
            self.downloadTask.downloadProgress = 1.0
        } else if totalBytesWritten <= 0 {
            self.downloadTask.downloadProgress = 0.0
        } else {
            self.downloadTask.downloadProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        }
    }
    
    func verifyDownloadAndMove(from: URL, to: URL, completionHandler: @escaping (Bool) -> Void) {
//        if MediaProcessor.fileNeedsOptimization(url: from) {
//            ATLog(.debug, "Media file needs optimization: \(from.absoluteString)")
//            MediaProcessor.optimizeQTFile(input: from, output: to, completionHandler: completionHandler)
//        } else {
//
//        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
            completionHandler(true)
        } catch {
            ATLog(.error, "FileManager removeItem error:\n\(error)")
            completionHandler(false)
        }
    }
}
