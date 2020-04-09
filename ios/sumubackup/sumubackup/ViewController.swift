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

    @IBOutlet weak var previewImage: UIImageView!
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var uploadPhotosButton: UIButton!
    @IBOutlet weak var uploadVideosButton: UIButton!

    var images = [UIImage]()
    var results: PHFetchResult<PHAsset>?
    var failedUploadCount: Int = 0
    var duplicates: Int = 0
    var timestamps: [UInt64: Bool] = [:]
    var timestampMutex = DispatchSemaphore(value: 0)
    var multipartUploadMutex = DispatchSemaphore(value: 0)
    var chunkMutex = DispatchSemaphore(value: 0)
    var uploadCallsGroup = DispatchGroup()
    var user: String = "vicky"
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

    static let CHECKING_SERVER_MSG = { (server: String) in "Checking if \(server) is online..." }
    static let SERVER_OFFLINE_MSG = { (server: String) in "\(server) is offline." }
    static let WELCOME_MSG = { (server: String) in "Upload iPhone media to \(server)!" }
    static let STARTING_UPLOAD = "Starting upload..."
    static let UPLOADING_MEDIA_MSG = { (type: String, number: Int, total: Int) in "Uploading \(type) \(String(number)) of \(String(total))..." }
    static let UPLOADS_FINISHED_MSG = { (type: String) in "Uploads finished. Check Plex for your \(type); if they're there, you can delete them from your phone." }
    static let SOME_UPLOADS_FAILED_MSG = { (type: String, number: Int, total: Int) in "\(String(number)) of \(String(total)) uploads failed. Careful when you delete \(type) from your phone!" }
    static let FINAL_DUPLICATES_MSG = { (type: String, server: String, duplicates: Int) in "Did not upload \(String(duplicates)) \(type) because they were already on \(server)." }
    static let DUPLICATE_MSG =  { (type: String, number: Int, total: Int) in "\(type) \(String(number)) of \(String(total)) is already on the server!" }

    static let ENV = "prod"  // TODO set to "dev" to call API at http://localhost:9090
    static let LOCALHOST = "0.0.0.0"
    static let SERVER = "galadriel"
    static let SAVE_URL = "http://{host}:9090/save"
    static let HEALTH_URL = "http://{host}:9090/health"
    static let TIMESTAMPS_URL = "http://{host}:9090/timestamps"

    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"
    static let RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS = DispatchTimeInterval.seconds(5)
    static let MAX_CHUNK_SIZE_BYTES = 6 << 20  // TODO increase to 6<<22

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        UIApplication.shared.isIdleTimerDisabled = true
        statusMessage.numberOfLines = 10
        statusMessage.lineBreakMode = .byWordWrapping
        statusMessage.text = ViewController.CHECKING_SERVER_MSG(ViewController.SERVER)
        if UIDevice.current.name.lowercased() == "goldberry" {
            user = "hamik"
        }

        checkIsServerOnline()
    }
    
    // Returns false if not going to proceed until user gives a better page total and page number
    func getMedia(mediaType: PHAssetMediaType) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
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
    
    func handleImageAsset(album: String, asset: PHAsset, assetNum: Int, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool) {
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true  // this is why we don't need a mutex for this method for sync behavior
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .none
        requestOptions.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
            guard let img = img else {
                print ("Image was nil")
                return
            }

            DispatchQueue.main.async { self.previewImage.image = img }
            if self.shouldUpload(timestamp: timestamp) {
                DispatchQueue.main.async {
                    self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG("image", assetNum, self.results!.count)
                }
                let imgB64 = img.pngData()!.base64EncodedString()
                if self.sendSingleChunkOverWire(album: album, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: .image, chunkBase64: imgB64) == nil {
                    self.failedUploadCount += 1
                }
            } else {
                self.duplicates += 1
                DispatchQueue.main.async {
                    self.statusMessage.text = ViewController.DUPLICATE_MSG("Image", assetNum, self.results!.count)
                }
            }
        }
        self.uploadCallsGroup.leave()
    }

    func getThumbnail(videoAsset: AVAsset) -> UIImage? {
        let thumbnailGenerator = AVAssetImageGenerator(asset: videoAsset)
        thumbnailGenerator.appliesPreferredTrackTransform = true
        let midpointTime = CMTimeMakeWithSeconds(1, preferredTimescale: 600)
        do {
            let img = try thumbnailGenerator.copyCGImage(at: midpointTime, actualTime: nil)
            let thumbnail = UIImage(cgImage: img)
            return thumbnail
        } catch {
            print(error.localizedDescription)
            return nil
        }
    }

//    func pullVideoAssetFromUrlAndUpload(url: URL, videoAsset: AVAsset, album: String, assetNum: Int, t: UInt64, lat: Double?, long: Double?, f: Bool) {
//        guard let videoDataStream = InputStream(url: url) else {
//            print("Unable to get video data stream! :-(")
//            return
//        }
//
//        let thumbnailPreview = self.getThumbnail(videoAsset: videoAsset)
//        DispatchQueue.main.async { self.previewImage.image = thumbnailPreview }
//        if self.shouldUpload(timestamp: t, sha256: nil, skipHashComparison: true) {
//            DispatchQueue.main.async {
//                self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG("video", assetNum, self.results!.count)
//            }
//            self.sendMediaOverWire(album: album, timestamp: t, latitude: lat, longitude: long, isFavorite: f, sha256: "", mediaType: .video, mediaB64: nil, inputStream: videoDataStream)
//        } else {
//            self.duplicates += 1
//            DispatchQueue.main.async {
//                self.statusMessage.text = ViewController.DUPLICATE_MSG("Video", assetNum, self.results!.count)
//            }
//        }
//    }

//    func handleVideoAsset(album: String, asset: PHAsset, assetNum: Int, t: UInt64, lat: Double?, long: Double?, f: Bool) {
//        let requestOptions = PHVideoRequestOptions()
//        requestOptions.deliveryMode = .highQualityFormat
//        requestOptions.isNetworkAccessAllowed = true
//
//        let manager = PHImageManager.default()
//        manager.requestAVAsset(forVideo: asset, options: requestOptions) { (videoAsset, audioMix, info) in
//            guard let videoAsset = videoAsset else {
//                print ("Nil video asset")
//                return
//            }
//
//            // Normal video
//            if let assetUrl = videoAsset as? ALAssetURL {
//                self.pullVideoAssetFromUrlAndUpload(url: assetUrl.url, videoAsset: videoAsset, album: album, assetNum: assetNum, t: t, lat: lat, long: long, f: f)
//            }
//
//            // Slow motion video
//            else if let assetComposition = videoAsset as? AVComposition, assetComposition.tracks.count > 1, let exporter = AVAssetExportSession(asset: assetComposition, presetName: AVAssetExportPresetHighestQuality) {
//
//                // Make sure we need to upload this slow mo video BASED ONLY ON ITS TIMESTAMP before doing a whole much of expensive stuff
//                guard self.shouldUpload(timestamp: t, sha256: nil, skipHashComparison: true) else {
//                    return
//                }
//
//                // Get temporary url to export slow-mo video to
//                let directory = NSTemporaryDirectory()
//                let fileName = NSUUID().uuidString
//                let fullURL = NSURL.fileURL(withPathComponents: [directory, fileName])
//
//                exporter.outputURL = fullURL
//                exporter.outputFileType = .mp4
//                exporter.canPerformMultiplePassesOverSourceMediaData = true
//                exporter.exportAsynchronously {
//                    DispatchQueue.main.sync {
//                        self.pullVideoAssetFromUrlAndUpload(url: exporter.outputURL!, videoAsset: videoAsset, album: album, assetNum: assetNum, t: t, lat: lat, long: long, f: f)
//                    }
//                }
//            }
//        }
//    }
    
    func handleVideoAsset(album: String, asset: PHAsset, assetNum: Int, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool) {
        var failed = false
        if shouldUpload(timestamp: timestamp) {
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
            guard let finalVideoAssetResource = fullSizeVideoAssetResource != nil ? fullSizeVideoAssetResource: videoAssetResource else {
                print ("Couldn't find video or fullVideo asset resource:", assetResources)
                exit(1)
            }

            // TODO: get thumbnail?

            DispatchQueue.main.async {
                self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG("video", assetNum, self.results!.count)
            }
            let managerRequestOptions = PHAssetResourceRequestOptions()
            managerRequestOptions.isNetworkAccessAllowed = true
            let manager = PHAssetResourceManager.default()
            var newUuid: String?
            manager.requestData(for: finalVideoAssetResource, options: managerRequestOptions, dataReceivedHandler: { (dataChunk: Data) in
                newUuid = self.sendSingleChunkOverWire(album: album, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite, mediaType: .video, chunkBase64: dataChunk.base64EncodedString(), uuid: newUuid)
                if newUuid == nil {
                    failed = true
                }
            }) { (err: Error? ) in
                if err != nil {
                    print ("Got an error in completion handler for multipart video upload:", err!)
                    failed = true
                }
                self.multipartUploadMutex.signal()
            }
            _ = self.multipartUploadMutex.wait(timeout: .distantFuture)
        } else {
            self.duplicates += 1
            DispatchQueue.main.async {
                self.statusMessage.text = ViewController.DUPLICATE_MSG("video", assetNum, self.results!.count)
            }
        }
        if failed {
            self.failedUploadCount += 1
        }
        self.uploadCallsGroup.leave()
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

                self.uploadCallsGroup.enter()
                if mediaType == .image {
                    handleImageAsset(album: album, asset: asset, assetNum: i + 1, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite)
                } else {
                    handleVideoAsset(album: album, asset: asset, assetNum: i + 1, timestamp: timestamp, latitude: latitude, longitude: longitude, isFavorite: isFavorite)
                }
                
            }
        }
    }
    
    func getUrl(endpoint: String) -> URL {
        let urlTemplate: String?
        var params = ""
        let passParam = "?p=" + ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL
        switch endpoint {
        case "save":
            urlTemplate = ViewController.SAVE_URL
        case "health":
            urlTemplate = ViewController.HEALTH_URL
            params = passParam
        case "timestamps":
            urlTemplate = ViewController.TIMESTAMPS_URL
            params = passParam + "&u=" + user
        default:
            urlTemplate = nil
        }
        let urlString = (urlTemplate!.replacingOccurrences(of: "{host}", with: (ViewController.ENV == "dev" ? ViewController.LOCALHOST : ViewController.SERVER)) + params)
        return URL(string: urlString)!
    }

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
                self.timestampMutex.signal()
            }
        }).resume()
        _ = timestampMutex.wait(timeout: .distantFuture)
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

    // Returns nil if chunk upload failed, otherwise returns the uuid of the row corresponding to the file we appended to
    func sendSingleChunkOverWire(album: String, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, mediaType: PHAssetMediaType, chunkBase64: String, uuid: String? = nil) -> String? {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "save"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "a": album, // second part of relative path on server
            "p": ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": chunkBase64,

            "u": user,  // user name, used as first path of relative path on server where photos will be stored
            "t": timestamp,
            "lat": latitude,
            "long": longitude,
            "f": isFavorite,
            "v": (mediaType == .image ? false : true),
            "d": uuid
        ]

        var newUuid: String?
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Upload failed. Error:", error ?? "nil error")
            } else {
                let jsonData = try? JSONSerialization.jsonObject(with: data!, options: .mutableContainers)
                let returnedJson = jsonData as! [String: String]
                newUuid = returnedJson["d"]
            }
            self.chunkMutex.signal()
        }).resume()
        _ = chunkMutex.wait(timeout: .distantFuture)
        return newUuid
    }

    func getAlbumString() -> String {
        return (albumField.text == nil || albumField.text!.count == 0) ? ViewController.DEFAULT_ALBUM_NAME : albumField.text!
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

// Handlers for buttons
extension ViewController {
    func setUploadButtons(enable: Bool) {
        uploadPhotosButton.isEnabled = enable
        uploadVideosButton.isEnabled = enable
    }

    func uploadMedia(mediaType: PHAssetMediaType) {
        getMedia(mediaType: mediaType)
        let itemCount = results!.count
        let album = getAlbumString()
        setUploadButtons(enable: false)

        DispatchQueue.global(qos: .background).async {
            self.getTimestamps()
            self.startUploads(album: album, mediaType: mediaType)

            // Show final status message
            self.uploadCallsGroup.notify(queue: .main) {
                if (self.failedUploadCount > 0) {
                    self.statusMessage.text = self.getSomeUploadsFailedMsg(mediaType: mediaType, itemCount: itemCount)
                } else {
                    self.statusMessage.text = self.getUploadsFinishedMsg(mediaType: mediaType)
                }
                self.setUploadButtons(enable: true)
            }
        }
    }
    
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
}
