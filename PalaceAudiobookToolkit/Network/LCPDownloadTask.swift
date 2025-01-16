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
 All audio files are embedded into LCP-protected audiobook file.
 */
final class LCPDownloadTask: DownloadTask {
    
    /// All encrypted files are included in the audiobook, download progress is 1.0
    let downloadProgress: Float = 1.0
    
    /// Spine element key
    let key: String
    
    /// URL of a file inside the audiobook archive (e.g., `media/sound.mp3`)
    let urls: [URL]
    
    /// URL for decrypted audio file
    var decryptedUrls: [URL]?
    
    let urlMediaType: LCPSpineElementMediaType
    
    weak var delegate: DownloadTaskDelegate?
    
    private static var cacheSubdirectory: String {
        return  (Bundle.main.bundleIdentifier ?? "lcp_cache") + "/cache"
    }
    
    init(spineElement: LCPSpineElement) {
        self.key = spineElement.key
        self.urls = spineElement.urls
        self.urlMediaType = spineElement.mediaType
        self.decryptedUrls = self.urls.compactMap { decryptedFileURL(for:$0) }
    }
    func fetch() {
        // No need to download files.
    }
    
    /// Delete decrypted file
        func delete() {
            let fileManager = FileManager.default
            decryptedUrls?.forEach {
                guard fileManager.fileExists(atPath: $0.path) else {
                    return
                }
    
                do {
                    try fileManager.removeItem(at: $0)
                } catch {
                    ATLog(.warn, "Could not delete decrypted file.", error: error)
                }
            }
        }
    
    /// Deletes all decrypted files stored in the cache directory
    ///
    /// This function attempts to remove all files located within the designated cache subdirectory.
    /// It iterates through each file found and attempts to delete it.
    /// Any errors during the process, such as failure to access the directory or delete a specific file, are logged.
    ///
    /// - Note: This function uses the `FileManager` to interact with the file system.
    func deleteCached() {
        let fileManager = FileManager.default
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            ATLog(.error, "Could not find caches directory.")
            return
        }
        
        let subdirectory = cacheDirectory.appendingPathComponent(Self.cacheSubdirectory, isDirectory: true)
        
        do {
            // Get all files in the cache directory
            let cachedFiles = try fileManager.contentsOfDirectory(at: subdirectory, includingPropertiesForKeys: nil)
            
            // Delete each file
            for fileURL in cachedFiles {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    ATLog(.warn, "Could not delete cached file at \(fileURL).", error: error)
                }
            }
        } catch {
            ATLog(.warn, "Could not access cache directory.", error: error)
        }
    }
    
    /// URL for decryption delegate to store decrypted file.
    /// - Parameter url: Internal file URL (e.g., `media/sound.mp3`).
    /// - Returns: `URL` to store decrypted file.
    private func decryptedFileURL(for url: URL) -> URL? {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        let subdirectory = cacheDirectory.appendingPathComponent(Self.cacheSubdirectory, isDirectory: true)
        
        // Create subdirectory if needed
        if !FileManager.default.fileExists(atPath: subdirectory.path, isDirectory: nil) {
            do {
                try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                ATLog(.error, "Could not create subdirectory.", error: error)
                return nil
            }
        }
        
        let toBeHashed = "\(url.path)-\(key)"
        guard let hashedUrl = toBeHashed.sha256?.hexString else {
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        return subdirectory.appendingPathComponent(hashedUrl).appendingPathExtension(url.pathExtension)
    }
}
