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
    
    @IBOutlet weak var previewImage: UIImageView!
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var totalPages: UITextField!
    @IBOutlet weak var pageToUpload: UITextField!
    @IBOutlet weak var uploadPhotosButton: UIButton!
    @IBOutlet weak var uploadVideosButton: UIButton!

    var images = [UIImage]()
    var results: PHFetchResult<PHAsset>?
    var failedUploadCount: Int = 0
    var duplicates: Int = 0
    var timestamps: [UInt64: [String]] = [:]
    var semaphore = DispatchSemaphore(value: 0)
    var uploadCallsGroup = DispatchGroup()
    var user: String = "vicky"
    var isServerOnline = false {
        didSet {
            if isServerOnline {
                uploadPhotosButton.isEnabled = true
                uploadVideosButton.isEnabled = true
                statusMessage.text = ViewController.WELCOME_MSG.replacingOccurrences(of: "{server}", with: ViewController.SERVER)
            } else {
                statusMessage.text = ViewController.SERVER_OFFLINE_MSG.replacingOccurrences(of: "{server}", with: ViewController.SERVER)
                DispatchQueue.main.asyncAfter(deadline: .now() + ViewController.RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS) {
                    self.checkIsServerOnline()
                }
            }
        }
    }

    static let CHECKING_SERVER_MSG = "Checking if {server} is online..."
    static let SERVER_OFFLINE_MSG = "{server} is offline."
    static let WELCOME_MSG = "Upload iPhone media to {server}!"
    static let STARTING_UPLOAD = "Starting upload..."
    static let UPLOADING_MEDIA_MSG = "Uploading {type} {number} of {total}..."
    static let UPLOADS_FINISHED_MSG = "Page {page} uploads finished. Check Plex for your {type}; if they're there, you can delete them from your phone."
    static let SOME_UPLOADS_FAILED_MSG = "{number} of {total} uploads failed. Careful when you delete {type} from your phone!"
    static let FINAL_DUPLICATES_MSG = "Did not upload {duplicates} {type} because they were already on {server}."
    static let DUPLICATE_MSG = "{type} {number} of {total} is already on the server!"
    static let TOO_MANY_ASSETS_MSG = "You can upload at most {max} {type} at once; you have {number}. Choose \"Total Pages\", set \"Page to Upload\" to 1, then upload. After uploading, change it to 2 and upload. When it equals \"Total Pages\", we'll try all {type} to make sure none are missed."

    static let ENV = "prod"  // set to "dev" to call API at http://localhost:9090
    static let LOCALHOST = "0.0.0.0"
    static let SERVER = "vingilot"
    static let SAVE_URL = "http://{host}:9090/save"
    static let HEALTH_URL = "http://{host}:9090/health"
    static let TIMESTAMPS_URL = "http://{host}:9090/timestamps"

    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"
    static let RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS = DispatchTimeInterval.seconds(5)
    static let TOO_MANY_MEDIA_THRESHOLD = 1000

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        UIApplication.shared.isIdleTimerDisabled = true
        statusMessage.numberOfLines = 10
        statusMessage.lineBreakMode = .byWordWrapping
        statusMessage.text = ViewController.CHECKING_SERVER_MSG.replacingOccurrences(of: "{server}", with: ViewController.SERVER)
        if UIDevice.current.name.lowercased() == "goldberry" {
            user = "hamik"
        }

        checkIsServerOnline()
    }
    
    // Returns false if not going to proceed until user gives a better page total and page number
    func getMedia(mediaType: PHAssetMediaType) -> Bool {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared, .typeUserLibrary, .typeiTunesSynced]
        results = PHAsset.fetchAssets(with: mediaType, options: fetchOptions)

        let totalNumberOfPages = getTotalPages()
        let pageSize = results!.count / totalNumberOfPages
        if pageSize > ViewController.TOO_MANY_MEDIA_THRESHOLD {
            return false
        }
        return true
    }

    func shouldUpload(timestamp: UInt64, sha256: String) -> Bool {
        let hashesForTimestamp = self.timestamps[timestamp]
        if hashesForTimestamp == nil {
            return true
        }
        if hashesForTimestamp!.firstIndex(of: sha256) == nil {
            return true
        }
        return false
    }
    
    func handleImageAsset(album: String, asset: PHAsset, assetNum: Int, t: UInt64, lat: Double?, long: Double?, f: Bool) {
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .none
        requestOptions.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
            guard let img = img else {
                print ("Image was nil")
                self.uploadCallsGroup.leave()
                return
            }

            let sha256 = img.sha256()
            DispatchQueue.main.async { self.previewImage.image = img }
            if self.shouldUpload(timestamp: t, sha256: sha256) {
                DispatchQueue.main.async {
                    self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG.replacingOccurrences(of: "{number}", with: String(assetNum)).replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{type}", with: "image")
                }
                let imgB64 = img.pngData()!.base64EncodedString()
                self.sendMediaOverWire(album: album, mediaB64: imgB64, timestamp: t, latitude: lat, longitude: long, isFavorite: f, sha256: sha256, mediaType: .image)
            } else {
                self.duplicates += 1
                DispatchQueue.main.async {
                    self.statusMessage.text = ViewController.DUPLICATE_MSG.replacingOccurrences(of: "{number}", with: String(assetNum)).replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{type}", with: "Image")
                }
                self.uploadCallsGroup.leave()
            }
        }
    }

    func getThumbnail(videoAsset: AVAsset) -> UIImage? {
        let thumbnailGenerator = AVAssetImageGenerator(asset: videoAsset)
        thumbnailGenerator.appliesPreferredTrackTransform = true
        let midpointTime = CMTimeMakeWithSeconds(videoAsset.duration.seconds / 2 * 600, preferredTimescale: 600)
        do {
            let img = try thumbnailGenerator.copyCGImage(at: midpointTime, actualTime: nil)
            let thumbnail = UIImage(cgImage: img)
            return thumbnail
        } catch {
            print(error.localizedDescription)
            return nil
        }
    }

    func handleVideoAsset(album: String, asset: PHAsset, assetNum: Int, t: UInt64, lat: Double?, long: Double?, f: Bool) {
        let requestOptions = PHVideoRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        manager.requestAVAsset(forVideo: asset, options: requestOptions) { (videoAsset, audioMix, info) in
            guard let videoAsset = videoAsset else {
                print ("Nil video asset")
                self.uploadCallsGroup.leave()
                return
            }

            if let assetUrl = videoAsset as? AVURLAsset {
                guard let videoData = try? Data(contentsOf: assetUrl.url) else {
                    print("Unable to get video data! :-(")
                    self.uploadCallsGroup.leave()
                    return
                }

                let thumbnailPreview = self.getThumbnail(videoAsset: videoAsset)
                let sha256 = videoData.sha256()

                DispatchQueue.main.async { self.previewImage.image = thumbnailPreview }
                if self.shouldUpload(timestamp: t, sha256: sha256) {
                    DispatchQueue.main.async {
                        self.statusMessage.text = ViewController.UPLOADING_MEDIA_MSG.replacingOccurrences(of: "{number}", with: String(assetNum)).replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{type}", with: "video")
                    }
                    let videoB64 = videoData.base64EncodedString()
                    self.sendMediaOverWire(album: album, mediaB64: videoB64, timestamp: t, latitude: lat, longitude: long, isFavorite: f, sha256: sha256, mediaType: .video)
                } else {
                    self.duplicates += 1
                    DispatchQueue.main.async {
                        self.statusMessage.text = ViewController.DUPLICATE_MSG.replacingOccurrences(of: "{number}", with: String(assetNum)).replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{type}", with: "Video")
                    }
                    self.uploadCallsGroup.leave()
                }
            }
        }
    }

    func startUploads(album: String, mediaType: PHAssetMediaType, totalNumberOfPages: Int, pageNum: Int) {
        if results == nil {
            return
        }

        failedUploadCount = 0
        duplicates = 0
        DispatchQueue.main.async {
            self.statusMessage.text = ViewController.STARTING_UPLOAD
        }

        // Get the range of indices that constitute this page. Try all images for the last page to make sure none are missed, since the user might take more photos between uploads of pages < totalNumberOfPages.
        let numAssetsInPage = results!.count / totalNumberOfPages
        let pageRange = pageNum != totalNumberOfPages ? (numAssetsInPage * (pageNum - 1))..<(numAssetsInPage * pageNum) : 0..<results!.count
        for i in pageRange {
            autoreleasepool { // make sure memory is freed, otherwise a few big files will crash the app
                let asset = results!.object(at: i)
                let t = UInt64((asset.creationDate ?? Date()).timeIntervalSince1970.magnitude * 1000)
                let lat = asset.location == nil ? nil : asset.location?.coordinate.latitude.nextUp
                let long = asset.location == nil ? nil : asset.location?.coordinate.longitude.nextUp
                let f = asset.isFavorite

                self.uploadCallsGroup.enter()
                if mediaType == .image {
                    handleImageAsset(album: album, asset: asset, assetNum: i + 1, t: t, lat: lat, long: long, f: f)
                } else {
                    handleVideoAsset(album: album, asset: asset, assetNum: i + 1, t: t, lat: lat, long: long, f: f)
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
                if let data = data, let jsonData = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers), let timestamps = jsonData as? [String: [String]] {
                    for (t, arr) in timestamps {
                        self.timestamps[UInt64(t)!] = arr
                    }
                }
            }
            self.semaphore.signal()
        }).resume()
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

    func sendMediaOverWire(album: String, mediaB64: String, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, sha256: String, mediaType: PHAssetMediaType) {
        let url = getUrl(endpoint: "save")
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "a": album, // second part of relative path on server
            "p": ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": mediaB64,  // image or video data

            "u": user,  // user name, used as first path of relative path on server where photos will be stored
            "t": timestamp,
            "lat": latitude,
            "long": longitude,
            "f": isFavorite,
            "s": sha256,
            "v": (mediaType == .image ? false : true)
        ]
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: [])
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                    print ("Upload failed. Error:", error ?? "nil error")
                    self.failedUploadCount += 1
                }
                self.uploadCallsGroup.leave()
            }
        }).resume()
    }

    func getAlbumString() -> String {
        return (albumField.text == nil || albumField.text!.count == 0) ? ViewController.DEFAULT_ALBUM_NAME : albumField.text!
    }

    func getTotalPages() -> Int {
        return max((totalPages.text == nil || totalPages.text!.count == 0) ? 1 : Int(totalPages.text!)!, 1)
    }

    func getPageToUpload() -> Int {
        return max(min((pageToUpload.text == nil || pageToUpload.text!.count == 0) ? 1 : Int(pageToUpload.text!)!, getTotalPages()), 1)
    }
}

// Handlers for buttons
extension ViewController {
    func getMediaThenUpload(mediaType: PHAssetMediaType) {
        guard getMedia(mediaType: mediaType) else {
            statusMessage.text = ViewController.TOO_MANY_ASSETS_MSG.replacingOccurrences(of: "{type}", with: (mediaType == .image ? "images" : "videos")).replacingOccurrences(of: "{number}", with: String(results!.count)).replacingOccurrences(of: "{max}", with: String(ViewController.TOO_MANY_MEDIA_THRESHOLD))
            return
        }
        uploadPhotosButton.isEnabled = false
        uploadVideosButton.isEnabled = false
        let album = getAlbumString()
        let totalNumberOfPages = getTotalPages()
        let pageNum = getPageToUpload()

        DispatchQueue.global(qos: .background).async {
            self.getTimestamps()
            _ = self.semaphore.wait(wallTimeout: .distantFuture)
            self.startUploads(album: album, mediaType: mediaType, totalNumberOfPages: totalNumberOfPages, pageNum: pageNum)

            // Show final status message
            self.uploadCallsGroup.notify(queue: .main) {
                let duplicatesMsg = self.duplicates > 0 ? " " + ViewController.FINAL_DUPLICATES_MSG.replacingOccurrences(of: "{duplicates}", with: String(self.duplicates)).replacingOccurrences(of: "{server}", with: ViewController.SERVER).replacingOccurrences(of: "{type}", with: (mediaType == .image ? "image(s)" : "video(s)")) : ""
                if (self.failedUploadCount > 0) {
                    self.statusMessage.text = ViewController.SOME_UPLOADS_FAILED_MSG.replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{number}", with: String(self.failedUploadCount)).replacingOccurrences(of: "{type}", with: (mediaType == .image ? "images" : "video")) + duplicatesMsg
                } else {
                    self.statusMessage.text = ViewController.UPLOADS_FINISHED_MSG.replacingOccurrences(of: "{type}", with: (mediaType == .image ? "images" : "videos")).replacingOccurrences(of: "{page}", with: String(pageNum)) + duplicatesMsg
                }
                self.uploadPhotosButton.isEnabled = true
                self.uploadVideosButton.isEnabled = true
            }
        }
    }

    @IBAction func uploadPhotosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        getMediaThenUpload(mediaType: .image)
    }

    @IBAction func uploadVideosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        getMediaThenUpload(mediaType: .video)
    }

    @IBAction func tapHandler(_ sender: UITapGestureRecognizer) {
        albumField.resignFirstResponder()
        totalPages.resignFirstResponder()
        pageToUpload.resignFirstResponder()
    }

    @IBAction func albumEnteredHandler(_ sender: UITextField, forEvent event: UIEvent) {
        albumField.resignFirstResponder()
    }
    @IBAction func totalPagesEnteredHandler(_ sender: UITextField, forEvent event: UIEvent) {
        totalPages.resignFirstResponder()
    }
    @IBAction func pageToUploadHandler(_ sender: UITextField, forEvent event: UIEvent) {
        pageToUpload.resignFirstResponder()
    }
}
