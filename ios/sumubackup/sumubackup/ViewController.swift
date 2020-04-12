//
//  ViewController.swift
//  sumubackup
//
//  Created by Hamik on 3/29/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import UIKit
import Photos

class ViewController: UIViewController {

    // Outlets for UI elements
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var uploadPhotosButton: UIButton!
    @IBOutlet weak var uploadVideosButton: UIButton!

    // Instance variables
    var hashMemos: [PHAsset: String]?
    var assetsCount = 0
    var timestampToAssetList: [UInt64: [PHAsset]]?
    var uploadCompleteIfRequired: [UInt64: [Bool]]?
    var duplicates: Int = 0
    var timestamps: [UInt64: Bool] = [:]
    var user: String = "vicky"
    var uploading = false
    var forceStopUploads = false
    var showedWelcomeMsg = false

    // Locks for async handler wrangling
    var getMediaHashesMutex = DispatchSemaphore(value: 0)
    var getTimestampsMutex = DispatchSemaphore(value: 0)
    var sendChunkOverWireAsyncGroup = DispatchGroup()
    var finalizeMultipartUploadMutex = DispatchSemaphore(value: 0)
    var handleAssetMutex = DispatchSemaphore(value: 0)
    var beforeFinishingLastUploadMutex = DispatchSemaphore(value: 0)
    var livenessCheckMutex = DispatchSemaphore(value: 0)
    var startUploadsGroup = DispatchGroup()

    // Keep checking if the server is online every few seconds
    var isServerOnline = false {
        didSet {
            isServerOnlineWatcherTasks(newValue: isServerOnline)

            // Keep performing a liveness check in case the connection goes down
            DispatchQueue.main.asyncAfter(deadline: .now() + ViewController.RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS) {
                self.checkIsServerOnline()
            }
        }
    }

    // Templated strings used for status messages
    static let CHECKING_SERVER_MSG = { (server: String) in "Checking if \(server) is online..." }
    static let SERVER_OFFLINE_MSG = { (server: String) in "\(server) is offline." }
    static let PREPARING_UPLOAD = "Preparing upload..."
    static let WELCOME_MSG = { (server: String) in "Upload iPhone media to \(server)!" }
    static let UPLOADING_MEDIA_MSG = { (type: String, number: Int, total: Int) in "Uploading \(type) \(String(number)) of \(String(total))..." }
    static let UPLOADS_FINISHED_MSG = { (type: String) in "Uploads finished. Check Plex for your \(type); if they're there, you can delete them from your phone." }
    static let SOME_UPLOADS_FAILED_MSG = { (type: String, number: Int, total: Int) in "\(String(number)) of \(String(total)) uploads failed. Careful when you delete \(type) from your phone!" }
    static let FINAL_DUPLICATES_MSG = { (type: String, server: String, duplicates: Int) in "Did not upload \(String(duplicates)) \(type) because they were already on \(server)." }
    static let DUPLICATE_MSG =  { (type: String, number: Int, total: Int) in "\(type) \(String(number)) of \(String(total)) is already on the server!" }
    static let UPLOAD_INTERRUPTED_MSG = { (server: String) in "Lost connection to \(server) while uploading. Retrying..." }

    // Constants
    static let SERVER = "galadriel"
    static let HEALTH_URL = "http://{host}:9090/health"
    static let TIMESTAMPS_URL = "http://{host}:9090/timestamps"
    static let PART_URL = "http://{host}:9090/part"
    static let SAVE_URL = "http://{host}:9090/save"
    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"
    static let RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS = DispatchTimeInterval.seconds(5)
    static let JPEG_COMPRESSION_QUALITY = CGFloat(1)

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

    func isServerOnlineWatcherTasks(newValue: Bool) {
        if newValue {  // if server is online
            if uploading {  // if we were uploading when we lost the connection, then signal to the uploading code to continue
                livenessCheckMutex.signal()
                forceStopUploads = false
            } else {
                setUploadButtons(enable: true)
                // Show welcome message if we haven't already or if the last message shown was server offline one
                if !showedWelcomeMsg || statusMessage.text == ViewController.SERVER_OFFLINE_MSG(ViewController.SERVER) {
                    statusMessage.text = ViewController.WELCOME_MSG(ViewController.SERVER)
                    showedWelcomeMsg = true
                }
            }
        } else {  // if server is unreachable
            if uploading {  // and if we were in the middle of an upload
                forceStopUploads = true
                statusMessage.text = ViewController.UPLOAD_INTERRUPTED_MSG(ViewController.SERVER)
            } else {  //  but if we just opened the app or are between uploads
                setUploadButtons(enable: false)
                statusMessage.text = ViewController.SERVER_OFFLINE_MSG(ViewController.SERVER)
            }
        }
    }
}

// Video and image code
extension ViewController {

    // Find the desired asset resource; there are many resource types, like .photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo
    func getFinalAssetResource(asset: PHAsset, mediaType: PHAssetMediaType, isLivePhoto: Bool) -> PHAssetResource? {

        // Determine preferred and backup resource types
        var preferredResourceType = mediaType == .video ? PHAssetResourceType.fullSizeVideo : PHAssetResourceType.fullSizePhoto
        var backupResourceType = mediaType == .video ? PHAssetResourceType.video : PHAssetResourceType.photo
        if isLivePhoto && mediaType == .video {  // if this request is for the video part of a live photo
            preferredResourceType = .fullSizePairedVideo
            backupResourceType = .pairedVideo
        }

        // Find the desired asset resource
        let assetResources = PHAssetResource.assetResources(for: asset)
        var chosenAssetResource: PHAssetResource?
        for assetResource in assetResources {
            if assetResource.type == preferredResourceType {
                chosenAssetResource = assetResource
            }
            if assetResource.type == backupResourceType && chosenAssetResource == nil {
                chosenAssetResource = assetResource
            }
        }
        if chosenAssetResource == nil {
            print ("Couldn't find preferred or backup asset resource; it probably needs to be downloaded from the cloud. Local resources for this asset were", assetResources)
            print ("Asked for", preferredResourceType, backupResourceType)
        }
        return chosenAssetResource
    }

    // Upload asset in chunks, blocking until the upload is complete or errors out
    func handleAsset(album: String, asset: PHAsset, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, mediaType: PHAssetMediaType, isLivePhoto: Bool, originalTimestamp: UInt64, offset: Int) {

        // Set up to retrieve asset resource
        let multipartUploadUuid = UUID().uuidString
        var num: Int = 0
        var failed = false

        // Get filename extension
        let finalAssetResource = getFinalAssetResource(asset: asset, mediaType: mediaType, isLivePhoto: isLivePhoto)
        let filename = finalAssetResource == nil ? "" : finalAssetResource!.originalFilename
        let splitFilename = filename.split(separator: ".")
        let fileExtension = splitFilename.count == 0 ? "" : String(splitFilename[splitFilename.count - 1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // If we got a HEIC image, we need to use PhotoManager to get another file type instead. If finalAssetResource was nil, it's probably because we have to fetch it from the network. Go into this branch if it was nil and fetch
        if fileExtension == "heic" || finalAssetResource == nil {
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.deliveryMode = .highQualityFormat
            requestOptions.resizeMode = .none
            requestOptions.isNetworkAccessAllowed = true

            let manager = PHImageManager.default()
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
                guard let img = img else {
                    print ("HEIC image retrieved from PHImageManager was nil")
                    failed = true
                    self.handleAssetMutex.signal()
                    return
                }

                // Upload a single chunk containing the whole heic image as a jpeg
                let imgB64 = img.jpegData(compressionQuality: ViewController.JPEG_COMPRESSION_QUALITY)!.base64EncodedString()
                self.sendChunkOverWireAsync(chunkBase64: imgB64, uuid: multipartUploadUuid, chunkNum: 1)

                // Finalize the upload after single chunk upload finishes
                self.sendChunkOverWireAsyncGroup.notify(queue: .global(qos: .background)) {
                    if !self.finalizeMultipartUpload(album: album, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: mediaType, uuid: multipartUploadUuid, numParts: 1, isLivePhoto: isLivePhoto, fileExtension: "jpg") {
                        print ("Error when completing HEIC multipart upload!")
                        failed = true
                    }
                    self.handleAssetMutex.signal()
                }
            }
        } else {
            // Get the asset resource chunks, upload them asyncronously, then do a final "concat" API call to stick the chunks together on the backend
            let managerRequestOptions = PHAssetResourceRequestOptions()
            managerRequestOptions.isNetworkAccessAllowed = true
            let manager = PHAssetResourceManager.default()
            manager.requestData(for: finalAssetResource!, options: managerRequestOptions, dataReceivedHandler: { (dataChunk: Data) in
                num += 1
                self.sendChunkOverWireAsync(chunkBase64: dataChunk.base64EncodedString(), uuid: multipartUploadUuid, chunkNum: num)
            }) { (err: Error? ) in

                // Completion handler: wait until all chunks finish uploading to do final API call to concat the uploaded parts
                self.sendChunkOverWireAsyncGroup.notify(queue: .global(qos: .background)) {
                    if err != nil {
                        print ("Got an error in completion handler for multipart upload:", err!)
                        failed = true
                    } else {
                        if !self.finalizeMultipartUpload(album: album, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: mediaType, uuid: multipartUploadUuid, numParts: num, isLivePhoto: isLivePhoto, fileExtension: fileExtension) {
                            print ("Error when completing multipart upload!")
                            failed = true
                        }
                    }
                    self.handleAssetMutex.signal()
                }
            }
        }

        _ = handleAssetMutex.wait(timeout: .distantFuture)
        if !failed {
            uploadCompleteIfRequired![originalTimestamp]![offset] = true
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

    func checkIsServerOnline(setInstanceVariable: Bool = true) {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "health"))
        req.httpMethod = "GET"
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                let newValue = error == nil ? true : false
                if (setInstanceVariable) {
                    self.isServerOnline = newValue
                } else {
                    self.isServerOnlineWatcherTasks(newValue: newValue)
                    self.beforeFinishingLastUploadMutex.signal()
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

    func finalizeMultipartUpload(album: String, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, mediaType: PHAssetMediaType, uuid: String, numParts: Int, isLivePhoto: Bool, fileExtension: String) -> Bool {
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
            "n": numParts,
            "l": isLivePhoto,
            "x": fileExtension
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
        let urlString = urlTemplate!.replacingOccurrences(of: "{host}", with: ViewController.SERVER) + params
        return URL(string: urlString)!
    }
}

// Status message getters
extension ViewController {

    func getDuplicatesMsg(mediaType: PHAssetMediaType) -> String {
        return self.duplicates > 0 ? " " + ViewController.FINAL_DUPLICATES_MSG((mediaType == .image ? "image(s)" : "video(s)"), ViewController.SERVER, self.duplicates) : ""
    }

    func getSomeUploadsFailedMsg(mediaType: PHAssetMediaType, numFailedUploads: Int) -> String {
        return ViewController.SOME_UPLOADS_FAILED_MSG(mediaType == .image ? "images" : "videos", numFailedUploads, self.assetsCount) + self.getDuplicatesMsg(mediaType: mediaType)
    }

    func getUploadsFinishedMsg(mediaType: PHAssetMediaType) -> String {
        return ViewController.UPLOADS_FINISHED_MSG(mediaType == .image ? "images" : "videos") + self.getDuplicatesMsg(mediaType: mediaType)
    }

    func getUploadingMsg(mediaType: PHAssetMediaType, assetNum: Int, isLivePhoto: Bool) -> String {
        var mediaTypeString = mediaType == .image ? "image" : "video"
        mediaTypeString = isLivePhoto ? "live photo" : mediaTypeString
        return ViewController.UPLOADING_MEDIA_MSG(mediaTypeString, assetNum, self.assetsCount)
    }
}

// Handlers and utility funcitons for UI elements
extension ViewController {

    @IBAction func uploadPhotosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        uploading = true
        uploadMedia(mediaType: .image)
    }

    @IBAction func uploadVideosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        uploading = true
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

    func getMediaHashes(from assets: [PHAsset], mediaType: PHAssetMediaType) -> [String] {
        guard let hashMemos = hashMemos else { return [] }
        var hashes: [String] = []
        for asset in assets {

            if hashMemos[asset] != nil {
                hashes.append(hashMemos[asset]!)
                continue
            }

            if mediaType == .image {
                let requestOptions = PHImageRequestOptions()
                requestOptions.isSynchronous = true
                requestOptions.deliveryMode = .highQualityFormat
                requestOptions.resizeMode = .none
                requestOptions.isNetworkAccessAllowed = true
                let manager = PHImageManager.default()
                manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, _) in
                    guard let img = img else {
                        print ("Nil image asset")
                        return
                    }
                    let hash = img.sha256()
                    self.hashMemos![asset] = hash
                    hashes.append(hash)
                }
            } else if mediaType == .video {
                let requestOptions = PHVideoRequestOptions()
                requestOptions.deliveryMode = .highQualityFormat
                requestOptions.isNetworkAccessAllowed = true

                let manager = PHImageManager.default()
                manager.requestAVAsset(forVideo: asset, options: requestOptions) { (videoAsset, _, _) in
                    defer { self.getMediaHashesMutex.signal() }
                    guard let videoAsset = videoAsset else {
                        print ("Nil video asset")
                        return
                    }
                    if let videoAssetUrl = videoAsset as? AVURLAsset {
                        guard let data = try? Data(contentsOf: videoAssetUrl.url) else {
                            print("Could not turn video asset into data, possibly because url points to cloud instead of disk")
                            return
                        }
                        let hash = data.sha256()
                        self.hashMemos![asset] = hash
                        hashes.append(hash)
                    }
                }
                _ = getMediaHashesMutex.wait(timeout: .distantFuture)
            }
        }
        return hashes
    }

    func getMedia(mediaType: PHAssetMediaType) {

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared, .typeUserLibrary, .typeiTunesSynced]
        let results = PHAsset.fetchAssets(with: mediaType, options: fetchOptions)

        // Iterate over results to build dict of timeststamp to array of PHAssets. The array should be de-duped with SHAs
        timestampToAssetList = [:]
        uploadCompleteIfRequired = [:]
        assetsCount = 0
        hashMemos = [:]
        for i in 0..<results.count {
            autoreleasepool {
                let asset = results[i]
                let timestamp = UInt64((asset.creationDate ?? Date()).timeIntervalSince1970.magnitude * 1000)
                let otherAssets = timestampToAssetList![timestamp]
                if otherAssets == nil {
                    timestampToAssetList![timestamp] = [asset]
                    uploadCompleteIfRequired![timestamp] = [false]
                } else {  // hash current image and compare it to the other images for this timestamp. If it's duped, skip
                    let currentHash = getMediaHashes(from: [asset], mediaType: mediaType)[0]
                    let otherHashes = getMediaHashes(from: otherAssets!, mediaType: mediaType)
                    if otherHashes.contains(currentHash) {
                        return
                    }
                    timestampToAssetList![timestamp]!.append(asset)
                    uploadCompleteIfRequired![timestamp]!.append(false)
                }
                assetsCount += 1
            }
        }
    }

    // This method either recommends uploading, recommends not uploading, or crashes. These corresond to no timestamp seen, timestamp is mapped to true, and timestamp is mapped to false. On the backend, if timesSeen is None, then we should recommend uploading. If it's 1, we should recommend not uploading. If it's 1 but for a live photo, that doesn't make sense — we should crash, since timesSeen should be 2. If it's 2 but they're for the photo and video parts of a live photo, we should recommend not uploading. If it's 2 but not for live photo, we should crash. If 3 or greater, we should crash.
    func shouldUpload(timestamp: UInt64) -> Bool {
        guard let occursExactlyOnce = self.timestamps[timestamp] else {
            return true
        }
        if !occursExactlyOnce {
            print("There was a photo timestamp collision at", timestamp)
            exit(1)
        }
        return false
    }

    // uploadCompleteIfRequired is a bitmap for successful uploads of assets associated with a particular timestamp. This method returns the index of the first timestamp such that some of its assets failed to asset
    func supremumOfContiguousSuccessfulUploadIndices() -> Int {
        guard let uploadCompleteIfRequired = uploadCompleteIfRequired else {
            print ("uploadCompleteIfRequired is nil")
            return Int.max
        }
        let sortedUploadCompleteIfRequiredKeys = uploadCompleteIfRequired.keys.sorted(by: >)
        for i in 0..<sortedUploadCompleteIfRequiredKeys.count {
            let key = sortedUploadCompleteIfRequiredKeys[i]
            let assetUploadedList = uploadCompleteIfRequired[key]!
            if !assetUploadedList.allSatisfy({ $0 == true }) {
                return i
            }
        }
        return uploadCompleteIfRequired.count
    }

    // Increments timestamp number by 1 ms until it gets to a timestamp that's not present in the current getMedia results. NOTE: this method might choose a timestamp that's already on the backend, in which case the asset that uses it will not be uploaded. Since this method is only used to spread timestamps for edge case photos from WhatsApp or shared albums, I think the risk is OK. The reason we don't check if the chosen timestamp is on the backend BEFORE trying to use it is we would end up uploading these images or videos every time.
    func getNextAvailableTimestamp(from startingTimestamp: UInt64, offset: Int) -> UInt64 {
        if offset == 0 {
            return startingTimestamp
        }
        var candidateTimestamp = getNextAvailableTimestamp(from: startingTimestamp, offset: offset - 1) + 1
        let currentTimestamps = timestampToAssetList!.keys
        while currentTimestamps.contains(candidateTimestamp) {
            candidateTimestamp += 1
        }
        return candidateTimestamp
    }

    // Used to track image upload number
    func getCumulativeAssetsBeforeTimestamp(sortedKeys: [UInt64]) -> [UInt64: Int] {
        var ret: [UInt64: Int] = [:]
        for i in 0..<sortedKeys.count {
            let currentTimestamp = sortedKeys[i]
            if i == 0 {
                ret[currentTimestamp] = 0
                continue
            }
            let previousTimestamp = sortedKeys[i - 1]
            let previousArray = timestampToAssetList![previousTimestamp]!
            ret[currentTimestamp] = ret[previousTimestamp]! + previousArray.count
        }
        return ret
    }

    func startUploads(origAlbumName: String, mediaType: PHAssetMediaType) {
        guard let timestampToAssetList = timestampToAssetList else { return }

        duplicates = 0
        var album = origAlbumName

        // Iterate over the dict timestampToAssetList. Call getNextAvailableTimestamp to spread timestamps when multiple assets have the same creation date.
        var i = 0
        let sortedTimestampToAssetListKeys = timestampToAssetList.keys.sorted(by: >)
        let cumulativeAssetsBeforeTimestamp = getCumulativeAssetsBeforeTimestamp(sortedKeys: sortedTimestampToAssetListKeys)
        while i < sortedTimestampToAssetListKeys.count {  // iterate over keys in dict

            autoreleasepool { // make sure memory is freed, otherwise a few big files will crash the app
                let origTimestamp = sortedTimestampToAssetListKeys[i]
                let assetsWithTimestamp = timestampToAssetList[origTimestamp]!

                for j in 0..<assetsWithTimestamp.count {  // iterate over the value in dict, which is an array of PHAsset
                    let asset = assetsWithTimestamp[j]
                    let latitude = asset.location == nil ? nil : asset.location?.coordinate.latitude.nextUp
                    let longitude = asset.location == nil ? nil : asset.location?.coordinate.longitude.nextUp
                    let isFavorite = asset.isFavorite
                    let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
                    let timestamp = getNextAvailableTimestamp(from: origTimestamp, offset: j)
                    let currentNum = cumulativeAssetsBeforeTimestamp[origTimestamp]! + j + 1

                    // Choose a date-based album name if none was entered
                    if origAlbumName == ViewController.DEFAULT_ALBUM_NAME {
                        let creationDate = asset.creationDate ?? Date()
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM"
                        album = formatter.string(from: creationDate)
                    }

                    // Just abort this upload attempt if the media is already on the backend
                    if shouldUpload(timestamp: timestamp) {
                        DispatchQueue.main.async { self.statusMessage.text = self.getUploadingMsg(mediaType: mediaType, assetNum: currentNum, isLivePhoto: isLivePhoto) }

                        handleAsset(album: album, asset: asset, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: mediaType, isLivePhoto: isLivePhoto, originalTimestamp: origTimestamp, offset: j)
                        if isLivePhoto {
                            handleAsset(album: album, asset: asset, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: .video, isLivePhoto: isLivePhoto, originalTimestamp: origTimestamp, offset: j)
                        }
                    } else {
                        duplicates += 1
                        uploadCompleteIfRequired![origTimestamp]![j] = true
                        DispatchQueue.main.async {
                            self.statusMessage.text = ViewController.DUPLICATE_MSG("video", i + 1, self.assetsCount)
                        }
                    }
                }
                i += 1

                // If we're about to leave the loop, wait for a health check on the server
                if i == sortedTimestampToAssetListKeys.count {
                    checkIsServerOnline(setInstanceVariable: false)
                    _ = beforeFinishingLastUploadMutex.wait(timeout: .distantFuture)
                }
                if forceStopUploads {
                    _ = livenessCheckMutex.wait(timeout: .distantFuture)
                    i = supremumOfContiguousSuccessfulUploadIndices()
                    getTimestamps()  // in case a successful upload snuck through
                    return  // from this autoreleasepool closure
                }
            }
        }
    }

    func getNumFailedUploads() -> Int {
        guard let uploadCompleteIfRequired = uploadCompleteIfRequired else { return 0 }
        var failures = 0
        for (_, boolArray) in uploadCompleteIfRequired {
            for bool in boolArray {
                if !bool {
                    failures += 1
                }
            }
        }
        return failures
    }

    // Upload all media in timestampToAssetList dict
    func uploadMedia(mediaType: PHAssetMediaType) {
        setUploadButtons(enable: false)
        let origAlbumName = getAlbumString()
        statusMessage.text = ViewController.PREPARING_UPLOAD

        DispatchQueue.global(qos: .background).async {
            self.getMedia(mediaType: mediaType)
            self.getTimestamps()
            self.startUploads(origAlbumName: origAlbumName, mediaType: mediaType)

            // Show final status message after all uploads complete
            DispatchQueue.main.async {
                self.uploading = false
                let numFailedUploads = self.getNumFailedUploads()
                if (numFailedUploads > 0) {
                    self.statusMessage.text = self.getSomeUploadsFailedMsg(mediaType: mediaType, numFailedUploads: numFailedUploads)
                } else {
                    self.statusMessage.text = self.getUploadsFinishedMsg(mediaType: mediaType)
                }
                self.setUploadButtons(enable: true)
            }
        }
    }
}
