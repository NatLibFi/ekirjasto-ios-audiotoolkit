//
//  Audiobook.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/12/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

@objc public enum DrmStatus:Int {
    public typealias RawValue = Int
    case failed
    case processing
    case succeeded
}

/// DRM Decryptor protocol - decrypts protected files
@objc public protocol DRMDecryptor {

    /// Decrypt protected file
    /// - Parameters:
    ///   - url: encrypted file URL.
    ///   - resultUrl: URL to save decrypted file at.
    ///   - completion: decryptor callback with optional `Error`.
    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (_ error: Error?) -> Void)
}

@objc public protocol SpineElement: class {
    var key: String { get }
    var downloadTask: DownloadTask { get }
    var chapter: ChapterLocation { get }
}

@objc public protocol Audiobook: class {
    var uniqueIdentifier: String { get }
    var annotationsId: String { get }
    var spine: [SpineElement] { get }
    var player: Player { get }
    var drmStatus: DrmStatus { get set }
    func checkDrmAsync()
    func deleteLocalContent()
    init?(JSON: Any?, audiobookId: String?)
}

/// Host app should instantiate a audiobook object with JSON.
/// This audiobook should then be able to construct utility classes
/// using data in the spine of that JSON.
@objcMembers public final class AudiobookFactory: NSObject {
    /// Instatiate an audiobook object with JSON data containing spine elements of the book
    /// - Parameters:
    ///   - JSON: Audiobook and spine elements data
    ///   - decryptor: Optional DRM decryptor for encrypted audio files
    ///   - token: Optional bearer token for protected audio files
    /// - Returns: Audiobook object
    public static func audiobook(_ JSON: Any?, bookID: String? = nil, decryptor: DRMDecryptor?, token: String? = nil) -> Audiobook? {
        guard let JSON = JSON as? [String: Any] else { return nil }
        let metadata = JSON["metadata"] as? [String: Any]
        let drm = metadata?["encrypted"] as? [String: Any]
        let possibleScheme = drm?["scheme"] as? String
        let audiobook: Audiobook?

        if let scheme = possibleScheme, scheme == "http://librarysimplified.org/terms/drm/scheme/FAE" {
            let FindawayAudiobookClass = NSClassFromString("NYPLAEToolkit.FindawayAudiobook") as? Audiobook.Type
            audiobook = FindawayAudiobookClass?.init(JSON: JSON, audiobookId: bookID ?? "")
        } else if let type = JSON["formatType"] as? String,
                  type == "audiobook-overdrive" {
            audiobook = OverdriveAudiobook(JSON: JSON, audiobookId: nil)
        } else if let manifestContext = JSON["@context"] as? String, manifestContext == LCPAudiobook.manifestContext, let decryptor = decryptor {
            audiobook = LCPAudiobook(JSON: JSON, decryptor: decryptor)
        } else {
            audiobook = OpenAccessAudiobook(JSON: JSON, token: token)
        }

        ATLog(.debug, "checkDrmAsync")
        audiobook?.checkDrmAsync()
        return audiobook
    }

    /// Instatiate an audiobook object with JSON data containing spine elements of the book
    /// - Parameters:
    ///   - JSON: Audiobook and spine elements data
    /// - Returns: Audiobook object
    public static func audiobook(_ JSON: Any?) -> Audiobook? {
        return self.audiobook(JSON, decryptor: nil)
    }
}
