//
//  LCPDownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 19.11.2020.
//  Copyright © 2020 Dean Silfen. All rights reserved.
//

import Foundation

let LCPDownloadTaskCompleteNotification = NSNotification.Name(rawValue: "LCPDownloadTaskCompleteNotification")

/**
 This file is created for protocol conformance.
 Handles the management of LCP-protected audiobook files including decryption and cleanup.
 All audio files are embedded into LCP-protected audiobook file.
 */
final class LCPDownloadTask: DownloadTask {
    
    /// All encrypted files are included in the audiobook, download progress is 1.0
    let downloadProgress: Float = 1.0
    
    /// Spine element key used for decryption
    let key: String
    
    /// URLs of files inside the audiobook archive (e.g., `media/sound.mp3`)
    let urls: [URL]
    
    /// URL for decrypted audio file
    var decryptedUrls: [URL]?
    
    let urlMediaType: LCPSpineElementMediaType
    
    weak var delegate: DownloadTaskDelegate?
    
    init(spineElement: LCPSpineElement) {
        self.key = spineElement.key
        self.urls = spineElement.urls
        self.urlMediaType = spineElement.mediaType
        self.decryptedUrls = self.urls.compactMap { decryptedFileURL(for:$0) }
    }
    
    func fetch() {
        // No need to download files as they are embedded
    }

    /// Deletes all decrypted files associated with this task
    func delete() {
        let fileManager = FileManager.default
        decryptedUrls?.forEach { url in
            guard fileManager.fileExists(atPath: url.path) else {
                return
            }
            do {
                try fileManager.removeItem(at: url)
                ATLog(.debug, "Successfully deleted decrypted file at: \(url.lastPathComponent)")
            } catch {
                ATLog(.warn, "Could not delete decrypted file at: \(url.lastPathComponent)", error: error)
            }
        }
    }

    /// Generates the URL where a decrypted file should be stored
    /// - Parameter url: Internal file URL (e.g., `media/sound.mp3`)
    /// - Returns: URL to store decrypted file, or nil if the path cannot be created
    private func decryptedFileURL(for url: URL) -> URL? {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        let toBeHashed = "\(url.path)-\(key)"
        guard let hashedUrl = toBeHashed.sha256?.hexString else {
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        
        return cacheDirectory
            .appendingPathComponent(hashedUrl).appendingPathExtension(url.pathExtension)
    }
    
    /// Checks if a given URL is one of the decrypted files managed by this task
    /// - Parameter url: URL to check
    /// - Returns: Whether the URL corresponds to a decrypted file of this task
    /// Cleans all decrypted files from the cache directory, even when audiobook is not available
    static func cleanAllDecryptedFiles() {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            ATLog(.error, "Could not find caches directory.")
            return
        }
        
        do {
            let fileManager = FileManager.default
            let cachedFiles = try fileManager.contentsOfDirectory(at: cacheDirectory,
                                                                includingPropertiesForKeys: nil)
            
            var filesRemoved = 0
            
            for file in cachedFiles {
              let fileName = file.lastPathComponent
              let fileExtension = file.pathExtension.lowercased()
              let nameWithoutExtension = file.deletingPathExtension().lastPathComponent
              
              // Check if the file name is a SHA-256 hash (64 characters hex)
              let isHashedFile = nameWithoutExtension.count == 64 &&
              nameWithoutExtension.range(of: "^[A-Fa-f0-9]{64}$",
                                         options: .regularExpression) != nil
              // Check if it's an audio file
              let isAudioFile = ["mp3", "m4a", "m4b"].contains(fileExtension)
              
              if isHashedFile && isAudioFile {
                do {
                  try fileManager.removeItem(at: file)
                  filesRemoved += 1
                  ATLog(.debug, "Removed cached file: \(fileName)")
                } catch {
                  ATLog(.warn, "Could not delete cached file: \(fileName)", error: error)
                }
              }
            }
            
            ATLog(.debug, "Cache cleanup completed. Removed \(filesRemoved) files.")
            
        } catch {
            ATLog(.error, "Error accessing cache directory", error: error)
        }
    }
}
