//
//  ViewController.swift
//  sumubackup
//
//  Created by Hamik on 3/29/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import UIKit
import Photos

// TODO
// 1. getVideos, figure out how to store those lol
// 2. get rid of TODOs below
class ViewController: UIViewController {
    
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var previewImage: UIImageView!
    @IBOutlet weak var uploadPhotosButton: UIButton!
    @IBOutlet weak var uploadVideosButton: UIButton!

    var images = [UIImage]()
    var results: PHFetchResult<PHAsset>?
    var failedUploadCount: Int = 0
    var duplicates: Int = 0
    var timestamps: [UInt64: [String]] = [:]
    var semaphore = DispatchSemaphore(value: 0)
    var uploadCallsGroup = DispatchGroup()
    var isServerOnline = false {
        didSet {
            if isServerOnline {
                uploadPhotosButton.isEnabled = true
                uploadVideosButton.isEnabled = true
                statusMessage.text = ViewController.WELCOME_MSG.replacingOccurrences(of: "{server}", with: ViewController.SERVER)
            } else {
                statusMessage.text = ViewController.SERVER_OFFLINE_MSG.replacingOccurrences(of: "{server}", with: ViewController.SERVER)
            }
        }
    }

    var user: String = "vicky"
    
    static let CHECKING_SERVER_MSG = "Checking if {server} is online..."
    static let SERVER_OFFLINE_MSG = "{server} is offline."
    static let WELCOME_MSG = "Upload iPhone media to {server}!"
    static let STARTING_UPLOAD = "Starting upload..."
    static let UPLOADING_IMAGE_MSG = "Uploading image {number} of {total}..."
    static let UPLOAD_FINISHED_MSG = "Uploads finished. Double check Plex for images; if they're there, you can delete photos from your phone."
    static let SOME_UPLOADS_FAILED_MSG = "{number} of {total} uploads failed. Careful when you delete images from your phone!"
    static let FINAL_DUPLICATES_MSG = "Did not upload {duplicates} images because they were already on {server}."
    static let DUPLICATE_MSG = "Image {number} of {total} is already on the server!"

    static let ENV = "prod" // TODO set
    static let LOCALHOST = "0.0.0.0"
    static let SERVER = "galadriel"  // TODO set
    static let SAVE_URL = "http://{host}:9090/save"
    static let HEALTH_URL = "http://{host}:9090/health"
    static let TIMESTAMPS_URL = "http://{host}:9090/timestamps"

    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"

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
    
    func getPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared, .typeUserLibrary, .typeiTunesSynced]
        results = PHAsset.fetchAssets(with: .image, options: fetchOptions)
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
    
    func startUploads(album: String) {
        if results == nil {
            return
        }

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .none
        requestOptions.isNetworkAccessAllowed = true
        
        failedUploadCount = 0
        duplicates = 0
        DispatchQueue.main.async {
            self.statusMessage.text = ViewController.STARTING_UPLOAD
        }

        for i in 0..<min(results!.count, 100) { // TODO remove min
            autoreleasepool { // make sure memory is freed, otherwise a few big files will crash the app
                let asset = results!.object(at: i)
                let t = UInt64((asset.creationDate ?? Date()).timeIntervalSince1970.magnitude * 1000)
                let lat = asset.location == nil ? nil : asset.location?.coordinate.latitude.nextUp
                let long = asset.location == nil ? nil : asset.location?.coordinate.longitude.nextUp
                let f = asset.isFavorite

                manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
                    let sha256 = img!.sha256()
                    self.uploadCallsGroup.enter()
                    DispatchQueue.main.async { self.previewImage.image = img! }
                    if self.shouldUpload(timestamp: t, sha256: sha256) {
                        DispatchQueue.main.async {
                            self.statusMessage.text = ViewController.UPLOADING_IMAGE_MSG.replacingOccurrences(of: "{number}", with: String(i + 1)).replacingOccurrences(of: "{total}", with: String(self.results!.count))
                        }
                        self.upload(img: img!, timestamp: t, latitude: lat, longitude: long, isFavorite: f, album: album, sha256: sha256)
                    } else {
                        self.duplicates += 1
                        DispatchQueue.main.async {
                            self.statusMessage.text = ViewController.DUPLICATE_MSG.replacingOccurrences(of: "{number}", with: String(i + 1)).replacingOccurrences(of: "{total}", with: String(self.results!.count))
                        }
                        self.uploadCallsGroup.leave()
                    }
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

    func upload(img: UIImage, timestamp: UInt64, latitude: Double?, longitude: Double?, isFavorite: Bool, album: String, sha256: String) {
        let url = getUrl(endpoint: "save")
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let imgBase64 = img.pngData()?.base64EncodedString()
        let jsonObj: [String: Any?] = [
            "a": album, // second part of relative path on server
            "p": ViewController.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": imgBase64,  // image data

            "u": user,  // user name, used as first path of relative path on server where photos will be stored
            "t": timestamp,
            "lat": latitude,
            "long": longitude,
            "f": isFavorite,
            "s": sha256,
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
}

// Handlers for buttons
extension ViewController {
    @IBAction func uploadPhotosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        let album = albumField.text ?? ViewController.DEFAULT_ALBUM_NAME
        getPhotos()
        DispatchQueue.global(qos: .background).async {
            self.getTimestamps()
            _ = self.semaphore.wait(wallTimeout: .distantFuture)
            self.startUploads(album: album)

            // Show final status message
            self.uploadCallsGroup.notify(queue: .main) {
                let duplicatesMsg = self.duplicates > 0 ? " " + ViewController.FINAL_DUPLICATES_MSG.replacingOccurrences(of: "{duplicates}", with: String(self.duplicates)).replacingOccurrences(of: "{server}", with: ViewController.SERVER) : ""
                if (self.failedUploadCount > 0) {
                    self.statusMessage.text = ViewController.SOME_UPLOADS_FAILED_MSG.replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{number}", with: String(self.failedUploadCount)) + duplicatesMsg
                } else {
                    self.statusMessage.text = ViewController.UPLOAD_FINISHED_MSG + duplicatesMsg
                }
            }
        }
    }

    @IBAction func uploadVideosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        print("shietttt")
    }

    @IBAction func albumEnteredHandler(_ sender: UITextField, forEvent event: UIEvent) {
        albumField.resignFirstResponder()
    }

    @IBAction func tapHandler(_ sender: UITapGestureRecognizer) {
        albumField.resignFirstResponder()
    }
}
