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
    var timestampToAssetList: [UInt64: [PHAsset]]?  // map from timestamp to all assets with that timestamp
    var hashMemos: [PHAsset: String]?  // used to store image or video SHAs to speed up the getMediaHashes method
    var uploadCompleteIfRequired: [UInt64: [Bool]]?  // bitmap for successful uploads of all assets with particular timestamp
    var assetsCount = 0  // total number of de-duped assets in timestampToAssetList
    var numAlreadyOnBackend: Int = 0  // number of uploads that weren't attempted because the asset's already on the server
    var timestamps: [UInt64: Bool] = [:]  // timestamps that have been seen on backend. nil if not seen, true if seen, false if it was seen an unexpected number of times (e.g., each live photo is stored on the server as a photo AND video, so it's timestamp should be seen exactly once. If it's seen once or three times, it will be mapped to false)
    var user: String = "vicky"  // is vicky by default unless the device's name is goldberry
    var uploading = false  // true if we're in the middle of an upload, false otherwise. Is used in isServerOnline watcher logic
    var forceStopUploads = false  // used in isServerOnline logic to stop uploads until the server connection is re-established
    var showedWelcomeMsg = false  // ensure that invitation to upload is only shown at launch and whenever it makes sense (e.g., after server comes online outside of an upload period)
    var isServerOnline = false {  // keep checking if the server is online every few seconds
        didSet {
            isServerOnlineWatcherTasks(newValue: isServerOnline)

            // Keep performing a liveness check in case the connection goes down
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS) {
                self.checkIsServerOnline()
            }
        }
    }

    // Locks for async handler wrangling
    var getMediaHashesMutex = DispatchSemaphore(value: 0)
    var getTimestampsMutex = DispatchSemaphore(value: 0)
    var sendChunkOverWireAsyncGroup = DispatchGroup()
    var finalizeMultipartUploadMutex = DispatchSemaphore(value: 0)
    var handleAssetMutex = DispatchSemaphore(value: 0)
    var beforeFinishingLastUploadMutex = DispatchSemaphore(value: 0)
    var livenessCheckMutex = DispatchSemaphore(value: 0)
    var startUploadsGroup = DispatchGroup()

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true  // make sure screen won't dim and device won't go to sleep
        statusMessage.numberOfLines = 10
        statusMessage.lineBreakMode = .byWordWrapping
        statusMessage.text = Constants.CHECKING_SERVER_MSG
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
            } else {  // re-enable buttons and show welcome message if we haven't or if the last message was "server offline"
                setUploadButtons(enable: true)
                if !showedWelcomeMsg || statusMessage.text == Constants.SERVER_OFFLINE_MSG {
                    statusMessage.text = Constants.WELCOME_MSG
                    showedWelcomeMsg = true
                }
            }
        } else {  // if server is unreachable
            if uploading {  // and if we were in the middle of an upload
                forceStopUploads = true
                statusMessage.text = Constants.UPLOAD_INTERRUPTED_MSG
            } else {  //  but if we just opened the app or are between uploads
                setUploadButtons(enable: false)
                statusMessage.text = Constants.SERVER_OFFLINE_MSG
            }
        }
    }
}

// Video and image code
extension ViewController {

    // Find the desired asset resource FROM DISK. There are many resource types, like .photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo.
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

    // Upload asset in chunks, blocking until the upload is complete or errors out.
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
                let imgB64 = img.jpegData(compressionQuality: Constants.JPEG_COMPRESSION_QUALITY)!.base64EncodedString()
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
        } else { // get the asset resource chunks, upload them asynchronously, then do a final "concat" API call to stick the chunks together on the backend
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

    // Fetch media asset metadata, then collect it into a timestamp --> [PHAsset] dict (timestampToAssetList) with de-duped assets. Also set up a parallel timestamp --> [Bool] dict (uploadCompleteIfRequired) that flags completed uploads. Note that the metadata fetched here might describe an image, a video, a live video, a slow-mo video, etc. It might also describe an asset that's present on disk or only present in iCloud.
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

    // Iterate over the dict timestampToAssetList, including each asset in the array of PHAsset. Call getNextAvailableTimestamp to spread timestamps when the array's size > 1. If the asset's timestamp isn't on the server, then upload it.
    func startUploads(origAlbumName: String, mediaType: PHAssetMediaType) {
        guard let timestampToAssetList = timestampToAssetList else { return }

        numAlreadyOnBackend = 0
        var album = origAlbumName

        var i = 0
        let sortedTimestampToAssetListKeys = timestampToAssetList.keys.sorted(by: >)
        let cumulativeAssetsBeforeTimestamp = Utilities.GetCumulativeAssetsBeforeTimestamp(within: timestampToAssetList, sortedKeys: sortedTimestampToAssetListKeys)
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
                    let timestamp = Utilities.GetNextAvailableTimestamp(from: origTimestamp, offset: j, within: timestampToAssetList)
                    let currentNum = cumulativeAssetsBeforeTimestamp[origTimestamp]! + j + 1

                    // Choose a date-based album name if none was entered
                    if origAlbumName == Constants.DEFAULT_ALBUM_NAME {
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
                        numAlreadyOnBackend += 1
                        uploadCompleteIfRequired![origTimestamp]![j] = true
                        DispatchQueue.main.async {
                            self.statusMessage.text = Constants.DUPLICATE_MSG(mediaType == .image ? "Image" : "Video", i + 1, self.assetsCount)
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
                    i = Utilities.SupremumOfContiguousSuccessfulUploadIndices(within: uploadCompleteIfRequired!)
                    getTimestamps()  // in case a successful upload snuck through
                    return  // from this autoreleasepool closure
                }
            }
        }
    }

    // Fetch media metadata, get the data from disk or iCloud, then upload it to the server.
    func uploadMedia(mediaType: PHAssetMediaType) {
        setUploadButtons(enable: false)
        let origAlbumName = getAlbumString()
        statusMessage.text = Constants.PREPARING_UPLOAD

        DispatchQueue.global(qos: .background).async {
            self.getMedia(mediaType: mediaType)
            self.getTimestamps()
            self.startUploads(origAlbumName: origAlbumName, mediaType: mediaType)

            // Show final status message after all uploads complete
            DispatchQueue.main.async {
                self.uploading = false
                let numFailedUploads = Utilities.GetNumFailedUploads(within: self.uploadCompleteIfRequired!)
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

// Local utilities
extension ViewController {

    func setUploadButtons(enable: Bool) {
        uploadPhotosButton.isEnabled = enable
        uploadVideosButton.isEnabled = enable
    }

    // Return the hashes of the full size images or videos corresponding to the the given array of assets.
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
}

// API calls
extension ViewController {

    // Syncronous method that gets known timestamps from backend. See shouldUpload for a complete discussion of the meaning of the values in the timestamps dict.
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

    // Set isServerOnline, which kicks off some watcher tasks AND schedules another checkIsServerOnline call for a few seconds later. Set setInstanceVariable to false to kick off watcher tasks WITHOUT scheduling another checkIsServerOnline call, which is useful if you have to manually call this function instead of relying on the automatically scheduled ones initiated by the call in viewDidLoad. This method is async if setInstanceVariable is true, synchronous otherwise (controlled by beforeFinishingLastUploadMutex)
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

    // Uploads the given chunk with the identifier uuid to the backend. This method is asynchronous, but it signals to sendChunkOverWireAsyncGroup so we can wait on completion of all chunk uploads as a group. I.e., each call is async but the group of calls is synchronous, assuming we enter the next chunk-upload before we leave all the previous ones. That seems like a reasonable assumption, since network uploads are much slower than disk access, but if the assumption is violated and finalizeMultipartUpload is kicked off prematurely, that call will fail and the user will (1) see a message about it after all uploads are finished, and (2) will be able to upload it again automatically next time they initiate a batch upload.
    func sendChunkOverWireAsync(chunkBase64: String, uuid: String, chunkNum: Int) {
        sendChunkOverWireAsyncGroup.enter()
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "part"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "p": Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": chunkBase64,
            "d": uuid,
            "o": chunkNum,
        ]
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Chunk upload failed. Error:", error ?? "nil error")
            }
             self.sendChunkOverWireAsyncGroup.leave()
        }).resume()
    }

    // Sends metadata for image or video identified by uuid to backend. Assumes that the media has already been uploaded and that all chunks have finished uploading, because this call starts concatenating those chunks. After it's done, it cleans up the temporary chunk files and writes metadata like latitude, isFavorite, etc. to the database. This method is synchronous.
    func finalizeMultipartUpload(album: String, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, mediaType: PHAssetMediaType, uuid: String, numParts: Int, isLivePhoto: Bool, fileExtension: String) -> Bool {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "save"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "a": album, // second part of relative path on server
            "p": Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
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

    // Gets URL for the given endpoint, including param part.
    func getUrl(endpoint: String) -> URL {
        var urlStringWithoutParams = ""
        var params = ""
        let passParam = "?p=" + Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL
        switch endpoint {
        case "health":
            urlStringWithoutParams = Constants.HEALTH_URL
            params = passParam
        case "timestamps":
            urlStringWithoutParams = Constants.TIMESTAMPS_URL
            params = passParam + "&u=" + user
        case "part":
            urlStringWithoutParams = Constants.PART_URL
        case "save":
            urlStringWithoutParams = Constants.SAVE_URL
        default:
            print("Unsupported endpoint:", endpoint)
            exit(1)
        }
        return URL(string: urlStringWithoutParams + params)!
    }
}

// Status message and other getters
extension ViewController {

    func getDuplicatesMsg(mediaType: PHAssetMediaType) -> String {
        return self.numAlreadyOnBackend > 0 ? " " + Constants.FINAL_DUPLICATES_MSG((mediaType == .image ? "image(s)" : "video(s)"), self.numAlreadyOnBackend) : ""
    }

    func getSomeUploadsFailedMsg(mediaType: PHAssetMediaType, numFailedUploads: Int) -> String {
        return Constants.SOME_UPLOADS_FAILED_MSG(mediaType == .image ? "images" : "videos", numFailedUploads, self.assetsCount) + self.getDuplicatesMsg(mediaType: mediaType)
    }

    func getUploadsFinishedMsg(mediaType: PHAssetMediaType) -> String {
        return Constants.UPLOADS_FINISHED_MSG(mediaType == .image ? "images" : "videos") + self.getDuplicatesMsg(mediaType: mediaType)
    }

    func getUploadingMsg(mediaType: PHAssetMediaType, assetNum: Int, isLivePhoto: Bool) -> String {
        var mediaTypeString = mediaType == .image ? "image" : "video"
        mediaTypeString = isLivePhoto ? "live photo" : mediaTypeString
        return Constants.UPLOADING_MEDIA_MSG(mediaTypeString, assetNum, self.assetsCount)
    }

    func getAlbumString() -> String {
        return (albumField.text == nil || albumField.text!.count == 0) ? Constants.DEFAULT_ALBUM_NAME : albumField.text!
    }
}

// Handlers for UI elements
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
}
