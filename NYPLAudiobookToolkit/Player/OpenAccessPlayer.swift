//
//  OpenAccessPlayer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/31/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

final class OpenAccessPlayer: NSObject, Player {
    var playbackRate: PlaybackRate = .normalTime
    
    var isLoaded = true
    
    func movePlayheadToLocation(_ location: ChapterLocation) {
        
    }
    
    func chapterIsPlaying(_ location: ChapterLocation) -> Bool {
        return false
    }
    
    var currentChapterLocation: ChapterLocation? = nil
    func registerDelegate(_ delegate: PlayerDelegate) {
    }
    
    func removeDelegate(_ delegate: PlayerDelegate) {
    }
    
    func seekTo(_ offsetInChapter: Float) {
    }
    
    var delegate: PlayerDelegate?
    func playAtLocation(_ chapter: ChapterLocation) {

    }
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((ChapterLocation)->())? = nil) -> () {
        
    }
    
    var isPlaying: Bool {
        return false
    }

    func play() {
        
    }
    
    func pause() {
        
    }
  
    func unload() {
        self.isLoaded = false
    }
}
