//
//  ViewController.swift
//  sumubackup
//
//  Created by Hamik on 3/29/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import UIKit
import Photos

// TODO: overhaul image upload so we use phassetresourcemanager instead of phimagemanager. why? better for backups... can get jpegs that are decent and can make sure we don't miss videos that go with live photos. EDIT: just tested... this approach is WAY WAY FASTER holy shit. tradeoff is i can't use thumbnails...
// TODO: test video uploads with slow motion (high framerate)
// TODO: support live photos by uploading photo part AND video part. need to check asset.mediaSubtypes to see if .photoLive
// TODO: consider getting rid of manual entry album name, replacing it with just the month and year
// TODO: (much later) need https
class ViewController: UIViewController {

    // Outlets for UI elements
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var uploadPhotosButton: UIButton!
    @IBOutlet weak var uploadVideosButton: UIButton!

    // Instance variables
    var results: PHFetchResult<PHAsset>?
    var failedUploadCount: Int = 0
    var duplicates: Int = 0
    var timestamps: [UInt64: Bool] = [:]
    var user: String = "vicky"

    // Locks for async handler wrangling
    var getTimestampsMutex = DispatchSemaphore(value: 0)
    var sendChunkOverWireAsyncGroup = DispatchGroup()
    var finalizeMultipartUploadMutex = DispatchSemaphore(value: 0)
    var handleVideoAssetMutex = DispatchSemaphore(value: 0)
    var startUploadsGroup = DispatchGroup()

    // Keep checking if the server is online every few seconds
    var isServerOnline = false {
        didSet {
            if isServerOnline {
                uploadPhotosButton.isEnabled = true
                uploadVideosButton.isEnabled = true
                statusMessage.text = ViewController.WELCOME_MSG(ViewController.SERVER)
            } else {
                statusMessage.text = ViewController.SERVER_OFFLINE_MSG(ViewController.SERVER)
                DispatchQueue.main.asyncAfter(deadline: .now() + ViewController.RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS) {
                    self.checkIsServerOnline()
                }
            }
        }
    }

    // Templated strings used for status messages
    static let CHECKING_SERVER_MSG = { (server: String) in "Checking if \(server) is online..." }
    static let SERVER_OFFLINE_MSG = { (server: String) in "\(server) is offline." }
    static let WELCOME_MSG = { (server: String) in "Upload iPhone media to \(server)!" }
    static let STARTING_UPLOAD = "Starting upload..."
    static let UPLOADING_MEDIA_MSG = { (type: String, number: Int, total: Int) in "Uploading \(type) \(String(number)) of \(String(total))..." }
    static let UPLOADS_FINISHED_MSG = { (type: String) in "Uploads finished. Check Plex for your \(type); if they're there, you can delete them from your phone." }
    static let SOME_UPLOADS_FAILED_MSG = { (type: String, number: Int, total: Int) in "\(String(number)) of \(String(total)) uploads failed. Careful when you delete \(type) from your phone!" }
    static let FINAL_DUPLICATES_MSG = { (type: String, server: String, duplicates: Int) in "Did not upload \(String(duplicates)) \(type) because they were already on \(server)." }
    static let DUPLICATE_MSG =  { (type: String, number: Int, total: Int) in "\(type) \(String(number)) of \(String(total)) is already on the server!" }

    // Constants
    static let ENV = "prod"  // TODO set to "dev" to call API at http://localhost:9090
    static let LOCALHOST = "0.0.0.0"
    static let SERVER = "galadriel"
    static let HEALTH_URL = "http://{host}:9090/health"
    static let TIMESTAMPS_URL = "http://{host}:9090/timestamps"
    static let PART_URL = "http://{host}:9090/part"
    static let SAVE_URL = "http://{host}:9090/save"
    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"
    static let RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS = DispatchTimeInterval.seconds(5)

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        statusMessage.numberOfLines = 10
        statusMessage.lineBreakMode = .byWordWrapping
        statusMessage.text = ViewController.CHECKING_SERVER_MSG(ViewController.SERVER)
        if UIDevice.current.name.lowercased() == "goldberry" {
            user = "hamik"
        }
        checkIsServerOnline()
    }
}

// Image code
extension ViewController {

    func handleImageAsset(album: String, asset: PHAsset, assetNum: Int, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool) {
    }
}

// Video code
extension ViewController {

    // Find the desired asset resource; there are many types, like .video and .fullSizeVideo
    func getFinalVideoAssetResource(asset: PHAsset) -> PHAssetResource {
        let assetResources = PHAssetResource.assetResources(for: asset)
        var videoAssetResource: PHAssetResource?
        var fullSizeVideoAssetResource: PHAssetResource?
        for assetResource in assetResources {
            switch assetResource.type {
            case .video:
                videoAssetResource = assetResource
            case .fullSizeVideo:
                fullSizeVideoAssetResource = assetResource
            default:
                continue
            }
        }
        guard let finalVideoAssetResource = (fullSizeVideoAssetResource != nil ? fullSizeVideoAssetResource: videoAssetResource) else {
            print ("Couldn't find video or fullVideo asset resource:", assetResources)
            exit(1)
        }
        return finalVideoAssetResource
    }

    // Upload video in chunks, blocking until the upload is complete or errors out
    func handleVideoAsset(album: String, asset: PHAsset, assetNum: Int, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool) {

        // Set up to retrieve asset resource
        DispatchQueue.main.async {
            self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG("video", assetNum, self.results!.count)
        }
        let multipartUploadUuid = UUID().uuidString
        var num: Int = 0
        var failed = false
        let finalVideoAssetResource = getFinalVideoAssetResource(asset: asset)
        let managerRequestOptions = PHAssetResourceRequestOptions()
        managerRequestOptions.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()

        // Get the asset resource chunks, upload them asyncronously, then do a final "concat" API call to stick the chunks together on the backend
        manager.requestData(for: finalVideoAssetResource, options: managerRequestOptions, dataReceivedHandler: { (dataChunk: Data) in
            num += 1
            self.sendChunkOverWireAsync(chunkBase64: dataChunk.base64EncodedString(), uuid: multipartUploadUuid, chunkNum: num)
        }) { (err: Error? ) in

            // Completion handler: wait until all chunks finish uploading to do final API call to concat the uploaded parts
            self.sendChunkOverWireAsyncGroup.notify(queue: .global(qos: .background)) {
                if err != nil {
                    print ("Got an error in completion handler for multipart video upload:", err!)
                    failed = true
                } else {
                    if !self.finalizeMultipartUpload(album: album, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: .video, uuid: multipartUploadUuid, numParts: num) {
                        print ("Error when completing multipart upload!")
                        failed = true
                    }
                }
                self.handleVideoAssetMutex.signal()
            }
        }
        _ = handleVideoAssetMutex.wait(timeout: .distantFuture)

        if failed {
            failedUploadCount += 1
        }
    }
}

// API calls
extension ViewController {

    func getTimestamps() {
        timestamps = [:]
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "timestamps"))
        req.httpMethod = "GET"
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                if let data = data, let jsonData = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers), let timestamps = jsonData as? [String: Bool] {
                    for (t, exists) in timestamps {
                        self.timestamps[UInt64(t)!] = exists
                    }
                }
                self.getTimestampsMutex.signal()
            }
        }).resume()
        _ = getTimestampsMutex.wait(timeout: .distantFuture)
    }

    func checkIsServerOnline() {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "health"))
        req.httpMethod = "GET"
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                if error == nil {
                    self.isServerOnline = true
                } else {
                    self.isServerOnline = false
                }
            }
        }).resume()
    }

    // Uploads the given chunkNum-th chunk with the identifier uuid to the backend. Is fire and forget/async.
    func sendChunkOverWireAsync(chunkBase64: String, uuid: String, chunkNum: Int) {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "part"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "p": ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": chunkBase64,
            "d": uuid,
            "o": chunkNum,
        ]

        sendChunkOverWireAsyncGroup.enter()
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Chunk upload failed. Error:", error ?? "nil error")
            }
             self.sendChunkOverWireAsyncGroup.leave()
        }).resume()
    }

    func finalizeMultipartUpload(album: String, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, mediaType: PHAssetMediaType, uuid: String, numParts: Int) -> Bool {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "save"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "a": album, // second part of relative path on server
            "p": ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "u": user,  // user name, used as first path of relative path on server where photos will be stored
            "t": timestamp,
            "lat": latitude,
            "long": longitude,
            "f": isFavorite,
            "v": (mediaType == .image ? false : true),
            "d": uuid,
            "n": numParts
        ]

        var failed = false
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Final multipart call failed. Error:", error ?? "nil error")
                failed = true
            }
            self.finalizeMultipartUploadMutex.signal()
        }).resume()
        _ = finalizeMultipartUploadMutex.wait(timeout: .distantFuture)
        return !failed
    }

    func getUrl(endpoint: String) -> URL {
        let urlTemplate: String?
        var params = ""
        let passParam = "?p=" + ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL
        switch endpoint {
        case "health":
            urlTemplate = ViewController.HEALTH_URL
            params = passParam
        case "timestamps":
            urlTemplate = ViewController.TIMESTAMPS_URL
            params = passParam + "&u=" + user
        case "part":
            urlTemplate = ViewController.PART_URL
        case "save":
            urlTemplate = ViewController.SAVE_URL
        default:
            urlTemplate = nil
        }
        let urlString = (urlTemplate!.replacingOccurrences(of: "{host}", with: (ViewController.ENV == "dev" ? ViewController.LOCALHOST : ViewController.SERVER)) + params)
        return URL(string: urlString)!
    }
}

// Status message getters
extension ViewController {

    func getDuplicatesMsg(mediaType: PHAssetMediaType) -> String {
        return self.duplicates > 0 ? " " + ViewController.FINAL_DUPLICATES_MSG((mediaType == .image ? "image(s)" : "video(s)"), ViewController.SERVER, self.duplicates) : ""
    }

    func getSomeUploadsFailedMsg(mediaType: PHAssetMediaType, itemCount: Int) -> String {
        return ViewController.SOME_UPLOADS_FAILED_MSG(mediaType == .image ? "images" : "video", self.failedUploadCount, itemCount) + self.getDuplicatesMsg(mediaType: mediaType)
    }

    func getUploadsFinishedMsg(mediaType: PHAssetMediaType) -> String {
        return ViewController.UPLOADS_FINISHED_MSG(mediaType == .image ? "images" : "videos") + self.getDuplicatesMsg(mediaType: mediaType)
    }
}

// Handlers and utility funcitons for UI elements
extension ViewController {

    @IBAction func uploadPhotosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        uploadMedia(mediaType: .image)
    }

    @IBAction func uploadVideosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        uploadMedia(mediaType: .video)
    }

    @IBAction func tapHandler(_ sender: UITapGestureRecognizer) {
        albumField.resignFirstResponder()
    }

    @IBAction func albumEnteredHandler(_ sender: UITextField, forEvent event: UIEvent) {
        albumField.resignFirstResponder()
    }

    func setUploadButtons(enable: Bool) {
        uploadPhotosButton.isEnabled = enable
        uploadVideosButton.isEnabled = enable
    }

    func getAlbumString() -> String {
        return (albumField.text == nil || albumField.text!.count == 0) ? ViewController.DEFAULT_ALBUM_NAME : albumField.text!
    }

    func getMedia(mediaType: PHAssetMediaType) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared, .typeUserLibrary, .typeiTunesSynced]
        results = PHAsset.fetchAssets(with: mediaType, options: fetchOptions)
    }

    func shouldUpload(timestamp: UInt64) -> Bool {
        guard let occursExactlyOnce = self.timestamps[timestamp] else {
            return true
        }

        if !occursExactlyOnce {
            print("There was a photo timestamp collision!")
            exit(1)
        }
        return false
    }

    func startUploads(album: String, mediaType: PHAssetMediaType) {
        guard let results = results else { return }

        failedUploadCount = 0
        duplicates = 0
        DispatchQueue.main.async { self.statusMessage.text = ViewController.STARTING_UPLOAD }

        for i in 0..<results.count {
            autoreleasepool { // make sure memory is freed, otherwise a few big files will crash the app
                let asset = results.object(at: i)
                let timestamp = UInt64((asset.creationDate ?? Date()).timeIntervalSince1970.magnitude * 1000)
                let latitude = asset.location == nil ? nil : asset.location?.coordinate.latitude.nextUp
                let longitude = asset.location == nil ? nil : asset.location?.coordinate.longitude.nextUp
                let isFavorite = asset.isFavorite

                // Just abort this upload attempt if the media is already on the backend
                if shouldUpload(timestamp: timestamp) {
                    if mediaType == .image {
                        handleImageAsset(album: album, asset: asset, assetNum: i + 1, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite)
                    } else {
                        handleVideoAsset(album: album, asset: asset, assetNum: i + 1, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite)
                    }
                } else {
                    duplicates += 1
                    DispatchQueue.main.async {
                        self.statusMessage.text = ViewController.DUPLICATE_MSG("video", i + 1, self.results!.count)
                    }
                }
            }
        }
    }

    // Upload all media in results array
    func uploadMedia(mediaType: PHAssetMediaType) {
        getMedia(mediaType: mediaType)
        let itemCount = results!.count
        let album = getAlbumString()
        setUploadButtons(enable: false)

        DispatchQueue.global(qos: .background).async {
            self.getTimestamps()
            self.startUploads(album: album, mediaType: mediaType)

            // Show final status message after all uploads complete
            DispatchQueue.main.async {
                if (self.failedUploadCount > 0) {
                    self.statusMessage.text = self.getSomeUploadsFailedMsg(mediaType: mediaType, itemCount: itemCount)
                } else {
                    self.statusMessage.text = self.getUploadsFinishedMsg(mediaType: mediaType)
                }
                self.setUploadButtons(enable: true)
            }
        }
    }
}
