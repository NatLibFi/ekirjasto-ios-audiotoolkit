import AVFoundation

let AudioInterruptionNotification =  AVAudioSession.interruptionNotification
let AudioRouteChangeNotification =  AVAudioSession.routeChangeNotification

class OpenAccessPlayer: NSObject, Player {
    var queuesEvents: Bool = false
    var taskCompletion: Completion? = nil

    var errorDomain: String {
        return OpenAccessPlayerErrorDomain
    }
    
    var taskCompleteNotification: Notification.Name {
        return OpenAccessTaskCompleteNotification
    }
    
    var interruptionNotification: Notification.Name {
        return AudioInterruptionNotification
    }
    
    var routeChangeNotification: Notification.Name {
        return AudioRouteChangeNotification
    }
    
    var isPlaying: Bool {
        return self.avQueuePlayerIsPlaying
    }
    
    var isDrmOk: Bool {
        didSet {
            if !isDrmOk {
                pause()
                notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil))
                unload()
            }
        }
    }
    
    @objc func setupNotifications() {
        // Get the default notification center instance.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleInterruption),
                       name: interruptionNotification,
                       object: nil)
        
        nc.addObserver(self,
                       selector: #selector(handleRouteChange),
                       name: routeChangeNotification,
                       object: nil)
    }

    private var avQueuePlayerIsPlaying: Bool = false {
        didSet {
            if let location = self.currentChapterLocation {
                if oldValue == false && avQueuePlayerIsPlaying == true {
                    self.notifyDelegatesOfPlaybackFor(chapter: location)
                } else if oldValue == true && avQueuePlayerIsPlaying == false {
                    self.notifyDelegatesOfPauseFor(chapter: location)
                }
            }
        }
    }

    /// AVPlayer returns 0 for being "paused", but the protocol expects the
    /// "user-chosen rate" upon playing.
    var playbackRate: PlaybackRate {
        set {
            if self.avQueuePlayer.rate != 0.0 {
                let rate = PlaybackRate.convert(rate: newValue)
                self.avQueuePlayer.rate = rate
            }

            savePlaybackRate(rate: newValue)
        }

        get {
            fetchPlaybackRate() ?? .normalTime
        }
    }

    var currentChapterLocation: ChapterLocation? {
        let avPlayerOffset = self.avQueuePlayer.currentTime().seconds
        let playerItemStatus = self.avQueuePlayer.currentItem?.status
        let offset: TimeInterval
        if !avPlayerOffset.isNaN && playerItemStatus == .readyToPlay {
            offset = avPlayerOffset
        } else {
            offset = 0
        }

        return ChapterLocation(
            number: self.chapterAtCurrentCursor.number,
            part: self.chapterAtCurrentCursor.part,
            duration: self.chapterAtCurrentCursor.duration,
            startOffset: self.chapterAtCurrentCursor.chapterOffset ?? 0,
            playheadOffset: offset,
            title: self.chapterAtCurrentCursor.title,
            audiobookID: self.audiobookID
        )
    }

    var isLoaded = true

    func play()
    {
        // Check DRM
        if !isDrmOk {
            ATLog(.warn, "DRM is flagged as failed.")
            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)
            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
            return
        }

        switch self.playerIsReady {
        case .readyToPlay:
            self.avQueuePlayer.play()
            let rate = PlaybackRate.convert(rate: self.playbackRate)
            if rate != self.avQueuePlayer.rate {
                self.avQueuePlayer.rate = rate
            }
        case .unknown:
            self.cursorQueuedToPlay = self.cursor
            ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
            if self.avQueuePlayer.currentItem == nil {
                if let fileStatus = assetFileStatus(self.cursor.currentElement.downloadTask) {
                    switch fileStatus {
                    case .saved(let savedURLs):
                        let item = createPlayerItem(files: savedURLs) ?? AVPlayerItem(url: savedURLs[0])
                        
                        if self.avQueuePlayer.canInsert(item, after: nil) {
                            self.avQueuePlayer.insert(item, after: nil)
                        }
                    case .missing(_):
                        self.rebuildOnFinishedDownload(task: self.cursor.currentElement.downloadTask)
                    default:
                        break
                    }
                }
            }
        case .failed:
            ATLog(.error, "Ready status is \"failed\".")
            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
            break
        }
    }

    private func createPlayerItem(files: [URL]) -> AVPlayerItem? {
        guard files.count > 1 else { return AVPlayerItem(url: files[0]) }

        let composition = AVMutableComposition()
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        do {
            for (index, file) in files.enumerated() {
                let asset = AVAsset(url: file)
                if index == files.count - 1 {
                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
                } else {
                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
                }
            }
        } catch {
            ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
            return nil
        }

        return AVPlayerItem(asset: composition)
    }

    func pause()
    {
        if self.isPlaying {
            self.avQueuePlayer.pause()
        } else if self.cursorQueuedToPlay != nil {
            self.cursorQueuedToPlay = nil
            NotificationCenter.default.removeObserver(self, name: taskCompleteNotification, object: nil)
            notifyDelegatesOfPauseFor(chapter: self.chapterAtCurrentCursor)
        }
    }
    func unload() {
        self.isLoaded = false
        
        // First, pause playback
        self.pause()
        
        // Clean up current chapter
        if let lcpTask = cursor.currentElement.downloadTask as? LCPDownloadTask {
            lcpTask.delete()
            ATLog(.debug, "Cleaned up current chapter files during unload")
        }
        // Clean up all decrypted files
        LCPDownloadTask.cleanAllDecryptedFiles()
        
        self.avQueuePlayer.removeAllItems()
        self.notifyDelegatesOfUnloadRequest()
        ATLog(.debug, "Unload completed")
    }
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((ChapterLocation)->())? = nil) -> () {
        guard let destination = currentChapterLocation?.update(playheadOffset: (currentChapterLocation?.playheadOffset ?? 0) + timeInterval)  else {
            ATLog(.error, "New chapter location could not be created from skip.")
            return
        }

        self.playAtLocation(destination)
        completion?(destination)
    }

    /// New Location's playhead offset could be oustide the bounds of audio, so
    /// move and get a reference to the actual new chapter location. Only update
    /// the cursor if a new queue can successfully be built for the player.
    ///
    /// - Parameter newLocation: Chapter Location with possible playhead offset
    ///   outside the bounds of audio for the current chapter
    func playAtLocation(_ newLocation: ChapterLocation, completion: Completion? = nil) {
        let currentChapter = self.chapterAtCurrentCursor
        let newPlayhead = move(cursor: self.cursor, to: newLocation)

        // Clean up files when changing chapters
        if !currentChapter.inSameChapter(other: newLocation) {
            // Clean current chapter
            if let lcpTask = cursor.currentElement.downloadTask as? LCPDownloadTask {
                lcpTask.delete()
                ATLog(.debug, "Cleaned up current chapter files during jump")
            }
        }
        
        guard let newItemDownloadStatus = assetFileStatus(newPlayhead.cursor.currentElement.downloadTask) else {
            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
            notifyDelegatesOfPlaybackFailureFor(chapter: newPlayhead.location, error)
            completion?(error)
            return
        }

        switch newItemDownloadStatus {
        case .saved(_):
            // If we're in the same AVPlayerItem, apply seek directly with AVPlayer.
            if newPlayhead.location.inSameChapter(other: self.chapterAtCurrentCursor) {
                self.seekWithinCurrentItem(newOffset: newPlayhead.location.playheadOffset)
                completion?(nil)
                return
            }
            // Otherwise, check for an AVPlayerItem at the new cursor, rebuild the player
            // queue starting from there, and then begin playing at that location.
            self.buildNewPlayerQueue(atCursor: newPlayhead.cursor) { (success) in
                if success {
                    self.cursor = newPlayhead.cursor
                    self.seekWithinCurrentItem(newOffset: newPlayhead.location.playheadOffset)
                    self.play()
                    completion?(nil)
                } else {
                    ATLog(.error, "Failed to create a new queue for the player. Keeping playback at the current player item.")
                    let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
                    self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
                    completion?(error)
                }
            }
        case .missing(_):
            guard self.playerIsReady != .readyToPlay || self.playerIsReady != .failed else {
                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.downloadNotFinished.rawValue, userInfo: nil)
                self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
                completion?(error)
                return
            }

            self.cursor = newPlayhead.cursor
            self.queuedSeekOffset = newPlayhead.location.playheadOffset
            self.taskCompletion = completion
            rebuildOnFinishedDownload(task: newPlayhead.cursor.currentElement.downloadTask)
            return
    
        case .unknown:
            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
            self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
            return
        }
    }

    func movePlayheadToLocation(_ location: ChapterLocation, completion: Completion? = nil)
    {
        self.playAtLocation(location, completion: completion)
        self.pause()
    }

    /// Moving within the current AVPlayerItem.
    private func seekWithinCurrentItem(newOffset: TimeInterval)
    {
        if self.avQueuePlayer.currentItem?.status != .readyToPlay {
            self.queuedSeekOffset = newOffset
            return
        }
        
        guard let currentItem = self.avQueuePlayer.currentItem else {
            ATLog(.error, "No current AVPlayerItem in AVQueuePlayer to seek with.")
            return
        }
        
        currentItem.seek(to: CMTimeMakeWithSeconds(Float64(newOffset), preferredTimescale: Int32(1))) { finished in
            if finished {
                ATLog(.debug, "Seek operation finished.")
                self.notifyDelegatesOfPlaybackFor(chapter: self.chapterAtCurrentCursor)
            } else {
                ATLog(.error, "Seek operation failed on AVPlayerItem")
            }
        }
    }

    func registerDelegate(_ delegate: PlayerDelegate)
    {
        self.delegates.add(delegate)
    }

    func removeDelegate(_ delegate: PlayerDelegate)
    {
        self.delegates.remove(delegate)
    }

    private var chapterAtCurrentCursor: ChapterLocation
    {
        return self.cursor.currentElement.chapter
    }

    /// The overall readiness of an AVPlayer and the currently queued AVPlayerItem's readiness values.
    /// You cannot play audio without both being "ready."
    fileprivate func overallPlayerReadiness(player: AVPlayer.Status, item: AVPlayerItem.Status?) -> AVPlayerItem.Status
    {
        let avPlayerStatus = AVPlayerItem.Status(rawValue: self.avQueuePlayer.status.rawValue) ?? .unknown
        let playerItemStatus = self.avQueuePlayer.currentItem?.status ?? .unknown
        if avPlayerStatus == playerItemStatus {
            ATLog(.debug, "overallPlayerReadiness::avPlayerStatus \(avPlayerStatus.description)")
            return avPlayerStatus
        } else {
            ATLog(.debug, "overallPlayerReadiness::playerItemStatus \(playerItemStatus.description)")
            return playerItemStatus
        }
    }

    /// This should only be set by the AVPlayer via KVO.
    private var playerIsReady: AVPlayerItem.Status = .unknown {
        didSet {
            switch playerIsReady {
            case .readyToPlay:
                // Perform any queued operations like play(), and then seek().
                if let cursor = self.cursorQueuedToPlay {
                    self.cursorQueuedToPlay = nil
                    self.buildNewPlayerQueue(atCursor: cursor) { success in
                        if success {
                            self.seekWithinCurrentItem(newOffset: self.chapterAtCurrentCursor.playheadOffset)
                            self.play()
                        } else {
                            ATLog(.error, "User attempted to play when the player wasn't ready.")
                            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.playerNotReady.rawValue, userInfo: nil)
                            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
                        }
                    }
                }
                if let seekOffset = self.queuedSeekOffset {
                    self.queuedSeekOffset = nil
                    self.seekWithinCurrentItem(newOffset: seekOffset)
                }
            case .failed:
                fallthrough
            case .unknown:
                break
            }
        }
    }

    private let avQueuePlayer: AVQueuePlayer
    private let audiobookID: String
    private var cursor: Cursor<SpineElement>
    private var queuedSeekOffset: TimeInterval?
    private var cursorQueuedToPlay: Cursor<SpineElement>?
    private var playerContext = 0

    var delegates: NSHashTable<PlayerDelegate> = NSHashTable(options: [NSPointerFunctions.Options.weakMemory])

    required init(cursor: Cursor<SpineElement>, audiobookID: String, drmOk: Bool) {

        self.cursor = cursor
        self.audiobookID = audiobookID
        self.isDrmOk = drmOk // Skips didSet observer
        self.avQueuePlayer = AVQueuePlayer()
        super.init()

        self.setupNotifications()
        self.buildNewPlayerQueue(atCursor: self.cursor) { _ in }

        if #available(iOS 10.0, *) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        } else {
            // https://forums.swift.org/t/using-methods-marked-unavailable-in-swift-4-2/14949
            AVAudioSession.sharedInstance().perform(NSSelectorFromString("setCategory:error:"),
                                                    with: AVAudioSession.Category.playback)
        }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])

        self.addPlayerObservers()
    }

    deinit {
        // Ensure playback is stopped
        self.pause()
        
        // Clean up current chapter
        if let lcpTask = cursor.currentElement.downloadTask as? LCPDownloadTask {
            lcpTask.delete()
        }
        
        // Clean up cache directory for any remaining files
        LCPDownloadTask.cleanAllDecryptedFiles()
        
        self.removePlayerObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }

    private func buildNewPlayerQueue(atCursor cursor: Cursor<SpineElement>, completion: (Bool)->())
    {
        let items = self.buildPlayerItems(fromCursor: cursor)
        if items.isEmpty {
            completion(false)
        } else {
            for item in self.avQueuePlayer.items() {
                NotificationCenter.default.removeObserver(self,
                                                          name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                          object: item)
            }
            self.avQueuePlayer.removeAllItems()
            for item in items {
                if self.avQueuePlayer.canInsert(item, after: nil) {
                    NotificationCenter.default.addObserver(self,
                                                           selector:#selector(currentPlayerItemEnded(item:)),
                                                           name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                           object: item)
                    self.avQueuePlayer.insert(item, after: nil)
                } else {
                    var errorMessage = "Cannot insert item: \(item). Discrepancy between AVPlayerItems and what could be inserted. "
                    if self.avQueuePlayer.items().count >= 1 {
                        errorMessage = errorMessage + "Returning as Success with a partially complete queue."
                        completion(true)
                    } else {
                        errorMessage = errorMessage + "No items were queued. Returning as Failure."
                        completion(false)
                    }
                    ATLog(.error, errorMessage)
                    return
                }
            }
            completion(true)
        }
    }

    /// Queue all valid AVPlayerItems from the cursor up to any spine element that's missing it.
    private func buildPlayerItems(fromCursor cursor: Cursor<SpineElement>?) -> [AVPlayerItem]
    {
        var items = [AVPlayerItem]()
        var cursor = cursor

        while (cursor != nil) {
            guard let fileStatus = assetFileStatus(cursor!.currentElement.downloadTask) else {
                cursor = nil
                continue
            }
            switch fileStatus {
            case .saved(let assetURLs):
                let playerItem = createPlayerItem(files: assetURLs) ?? AVPlayerItem(url: assetURLs[0])
                playerItem.audioTimePitchAlgorithm = .timeDomain
                items.append(playerItem)
            case .missing(_):
                fallthrough
            case .unknown:
                cursor = nil
                continue
            }
            cursor = cursor?.next()
        }
        return items
    }

    /// Update the cursor if the next item in the queue is about to be put on.
    /// Not needed for explicit seek operations. Check the player for any more
    /// AVPlayerItems so that we can potentially rebuild the queue if more
    /// downloads have completed since the queue was last built.
    // Update currentPlayerItemEnded to handle cleanup during chapter transitions
    @objc func currentPlayerItemEnded(item: AVPlayerItem? = nil) {
        DispatchQueue.main.async {
            let currentCursor = self.cursor
            
            // Clean up the current chapter's files before moving to next
            if let lcpTask = currentCursor.currentElement.downloadTask as? LCPDownloadTask {
                lcpTask.delete()
            }
            
            if let nextCursor = self.cursor.next() {
                self.cursor = nextCursor
                
                if self.avQueuePlayer.items().count <= 1 {
                    self.pause()
                    ATLog(.debug, "Attempting to recover the missing AVPlayerItem.")
                    self.attemptToRecoverMissingPlayerItem(cursor: currentCursor)
                }
            } else {
                ATLog(.debug, "End of book reached.")
                self.pause()
            }
            
            self.notifyDelegatesOfPlaybackEndFor(chapter: currentCursor.currentElement.chapter)
        }
    }
    
    @objc func advanceToNextPlayerItem() {
        let currentCursor = self.cursor
        guard let nextCursor = self.cursor.next() else {
            ATLog(.debug, "End of book reached.")
            self.pause()
            return
        }

        self.cursor = nextCursor
        self.avQueuePlayer.advanceToNextItem()
        seekWithinCurrentItem(newOffset: Double(self.cursor.currentElement.chapter.chapterOffset?.seconds ?? 0))
        self.notifyDelegatesOfPlaybackEndFor(chapter: currentCursor.currentElement.chapter)
    }

    /// Try and recover from a Cursor missing its player asset.
    func attemptToRecoverMissingPlayerItem(cursor: Cursor<SpineElement>)
    {
        if let fileStatus = assetFileStatus(self.cursor.currentElement.downloadTask) {
            switch fileStatus {
            case .saved(_):
                self.rebuildQueueAndSeekOrPlay(cursor: cursor)
            case .missing(_):
                self.rebuildOnFinishedDownload(task: self.cursor.currentElement.downloadTask)
            case .unknown:
                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.playerNotReady.rawValue, userInfo: nil)
                self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
            }
        } else {
            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
        }
    }

    // Will seek to new offset and pause, if provided.
    func rebuildQueueAndSeekOrPlay(cursor: Cursor<SpineElement>, newOffset: TimeInterval? = nil)
    {
        buildNewPlayerQueue(atCursor: self.cursor) { (success) in
            if success {
                if let newOffset = newOffset {
                    self.seekWithinCurrentItem(newOffset: newOffset)
                } else {
                    self.play()
                }
            } else {
                ATLog(.error, "Ready status is \"failed\".")
                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
                self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
            }
        }
    }

    fileprivate func rebuildOnFinishedDownload(task: DownloadTask)
    {
        ATLog(.debug, "Added observer for missing download task.")
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.downloadTaskFinished),
                                               name: taskCompleteNotification,
                                               object: task)
    }

    @objc func downloadTaskFinished()
    {
        self.rebuildQueueAndSeekOrPlay(cursor: self.cursor, newOffset: self.queuedSeekOffset)
        self.taskCompletion?(nil)
        self.taskCompletion = nil
        NotificationCenter.default.removeObserver(self, name: taskCompleteNotification, object: nil)
    }
    
    func assetFileStatus(_ task: DownloadTask) -> AssetResult? {
        guard let task = task as? OpenAccessDownloadTask else {
            return nil
        }
        return task.assetFileStatus()
    }
}

/// Key-Value Observing on AVPlayer properties and items
extension OpenAccessPlayer{
    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?)
    {
        guard context == &playerContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        func updatePlayback(player: AVPlayer, item: AVPlayerItem?) {
            ATLog(.debug, "updatePlayback, playerStatus: \(player.status.description) item: \(item?.status.description ?? "")")
            DispatchQueue.main.async {
                self.playerIsReady = self.overallPlayerReadiness(player: player.status, item: item?.status)
            }
        }

        func avPlayer(isPlaying: Bool) {
            DispatchQueue.main.async {
                if self.avQueuePlayerIsPlaying != isPlaying {
                    self.avQueuePlayerIsPlaying = isPlaying
                }
            }
        }

        if keyPath == #keyPath(AVQueuePlayer.status) {
            let status: AVQueuePlayer.Status
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVQueuePlayer.Status(rawValue: statusNumber.intValue)!
            } else {
                status = .unknown
            }

            switch status {
            case .readyToPlay:
                ATLog(.debug, "AVQueuePlayer status: ready to play.")
            case .failed:
                let error = (object as? AVQueuePlayer)?.error.debugDescription ?? "error: nil"
                ATLog(.error, "AVQueuePlayer status: failed. Error:\n\(error)")
            case .unknown:
                ATLog(.debug, "AVQueuePlayer status: unknown.")
            }

            if let player = object as? AVPlayer {
                updatePlayback(player: player, item: player.currentItem)
            }
        }
        else if keyPath == #keyPath(AVQueuePlayer.rate) {
            if let newRate = change?[.newKey] as? Float,
                let oldRate = change?[.oldKey] as? Float,
                let player = (object as? AVQueuePlayer) {
                if (player.error == nil) {
                    if (oldRate == 0.0) && (newRate != 0.0) {
                        avPlayer(isPlaying: true)
                    } else if (oldRate != 0.0) && (newRate == 0.0) {
                        avPlayer(isPlaying: false)
                    }
                    return
                } else {
                    ATLog(.error, "AVPlayer error: \n\(player.error.debugDescription)")
                }
            }
            avPlayer(isPlaying: false)
            ATLog(.error, "KVO Observing did not deserialize correctly.")
        }
        else if keyPath == #keyPath(AVQueuePlayer.currentItem.status) {
            let oldStatus: AVPlayerItem.Status
            let newStatus: AVPlayerItem.Status
            if let oldStatusNumber = change?[.oldKey] as? NSNumber,
            let newStatusNumber = change?[.newKey] as? NSNumber {
                oldStatus = AVPlayerItem.Status(rawValue: oldStatusNumber.intValue)!
                newStatus = AVPlayerItem.Status(rawValue: newStatusNumber.intValue)!
            } else {
                oldStatus = .unknown
                newStatus = .unknown
            }

            if let player = object as? AVPlayer,
                oldStatus != newStatus {
                updatePlayback(player: player, item: player.currentItem)
            }
        }
        else if keyPath == #keyPath(AVQueuePlayer.reasonForWaitingToPlay) {
            if let reason = change?[.newKey] as? AVQueuePlayer.WaitingReason {
                ATLog(.debug, "Reason for waiting to play: \(reason)")
            }
        }
    }

    fileprivate func notifyDelegatesOfPlaybackFor(chapter: ChapterLocation) {
        self.delegates.allObjects.forEach { (delegate) in
            delegate.player(self, didBeginPlaybackOf: chapter)
        }
    }

    fileprivate func notifyDelegatesOfPauseFor(chapter: ChapterLocation) {
        self.delegates.allObjects.forEach { (delegate) in
            delegate.player(self, didStopPlaybackOf: chapter)
        }
    }

    fileprivate func notifyDelegatesOfPlaybackFailureFor(chapter: ChapterLocation, _ error: NSError?) {
        self.delegates.allObjects.forEach { (delegate) in
            delegate.player(self, didFailPlaybackOf: chapter, withError: error)
        }
    }

    fileprivate func notifyDelegatesOfPlaybackEndFor(chapter: ChapterLocation) {
        self.delegates.allObjects.forEach { (delegate) in
            delegate.player(self, didComplete: chapter)
        }
    }

    fileprivate func notifyDelegatesOfUnloadRequest() {
        self.delegates.allObjects.forEach { (delegate) in
            delegate.playerDidUnload(self)
        }
    }

    fileprivate func addPlayerObservers() {
        self.avQueuePlayer.addObserver(self,
                                       forKeyPath: #keyPath(AVQueuePlayer.status),
                                       options: [.old, .new],
                                       context: &playerContext)

        self.avQueuePlayer.addObserver(self,
                                       forKeyPath: #keyPath(AVQueuePlayer.rate),
                                       options: [.old, .new],
                                       context: &playerContext)

        self.avQueuePlayer.addObserver(self,
                                       forKeyPath: #keyPath(AVQueuePlayer.currentItem.status),
                                       options: [.old, .new],
                                       context: &playerContext)
        
        self.avQueuePlayer.addObserver(self,
                                       forKeyPath: #keyPath(AVQueuePlayer.reasonForWaitingToPlay),
                                       options: [.old, .new],
                                       context: &playerContext)
    }

    fileprivate func removePlayerObservers() {
        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.status))
        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.rate))
        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.currentItem.status))
        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.reasonForWaitingToPlay))
        NotificationCenter.default.removeObserver(self, name: interruptionNotification, object: nil)
    }

    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                    return
            }

            switch type {
            case .began:
                ATLog(.warn, "System audio interruption began.")
            case .ended:
                ATLog(.warn, "System audio interruption ended.")
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    play()
                } else {
                    play()
                }
            default: ()
            }
    }
    
    @objc func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue:reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            let session = AVAudioSession.sharedInstance()
            for output in session.currentRoute.outputs {
                switch output.portType {
                case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
                    play()
                default: ()
                }
            }
        case .oldDeviceUnavailable:
            if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                for output in previousRoute.outputs {
                    switch output.portType {
                    case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
                        pause()
                    default: ()
                    }
                }
            }
        default: ()
        }
    }
}
