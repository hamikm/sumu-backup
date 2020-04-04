//
//  ViewController.swift
//  sumubackup
//
//  Created by Hamik on 3/29/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import UIKit
import Photos


// TODO: remove these notes periodically
// Need to figure out how to key the metadata table on the backend so i can rapidly figure out if an image has been uploaded yet
// maybe display thumbnail of image that's being uploaded in ios app? not sure if worth the effort

class ViewController: UIViewController {
    
    @IBOutlet weak var statusMessage: UILabel!
    @IBOutlet weak var albumField: UITextField!
    @IBOutlet weak var uploadButton: UIButton!
    @IBOutlet weak var previewImage: UIImageView!
    
    var images = [UIImage]()
    var results: PHFetchResult<PHAsset>? {
        didSet {
            if results != nil {
                uploadButton.isEnabled = true
            }
        }
    }
    var failedUploadCount: Int = 0
    
    var user: String = "vicky"
    
    let WELCOME_MSG = "Click the buttons below to get started!"
    let FOUND_IMAGES_MSG = "Found {total} images that have not been uploaded to vingilot. Press Upload to upload them."
    let STARTING_UPLOAD = "Starting upload."
    let UPLOADED_IMAGE_MSG = "Uploaded image {number} of {total}!"
    let UPLOAD_FINISHED_MSG = "Uploads completed successfully. Double check Plex for the uploaded images. If they're there, you can delete photos from your phone."
    let SOME_UPLOADS_FAILED = "{number} of {total} uploads FAILED. Exercise caution when you delete images from your phone; some didn't make it onto the backup server!"
    let UPLOAD_FAILED_MSG = "Upload FAILED for image {number} of {total}!"

    let DEV_UPLOAD_URL = "http://0.0.0.0:9090/save"
    let DEV_CHECK_URL = "http://0.0.0.0:9090/check"
    let PROD_UPLOAD_URL = "http://vingilot:9090/save"
    let PROD_CHECK_URL = "http://0.0.0.0:9090/check"
    
    let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    let DEFAULT_ALBUM_NAME = "default"

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        statusMessage.numberOfLines = 10
        statusMessage.lineBreakMode = .byWordWrapping
        statusMessage.text = WELCOME_MSG

        if UIDevice.current.name.lowercased() == "goldberry" {
            user = "hamik"
        }
    }
    
    func getPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared, .typeUserLibrary, .typeiTunesSynced]
        results = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        statusMessage.text = FOUND_IMAGES_MSG.replacingOccurrences(of: "{total}", with: String(results!.count))
    }
    
    func startUpload() {
        if results == nil {
            return
        }

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .none
        requestOptions.isNetworkAccessAllowed = true
        
        DispatchQueue.main.async {
            self.failedUploadCount = 0
            self.statusMessage.text = self.STARTING_UPLOAD
        }

        for i in 0..<results!.count {
            print("Waiting for upload of image", i - 1)
            let asset = results!.object(at: i)
            let t = Int((asset.creationDate ?? Date()).timeIntervalSince1970.nextUp)
            let lat = asset.location == nil ? nil : asset.location?.coordinate.latitude.nextUp
            let long = asset.location == nil ? nil : asset.location?.coordinate.longitude.nextUp
            let f = asset.isFavorite

            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
                DispatchQueue.main.async {
                    self.previewImage.image = img
                }
                self.upload(img: img!, count: i + 1, total: self.results!.count, timestamp: t, latitude: lat, longitude: long, isFavorite: f)
            }
        }
    }
    
    func upload(img: UIImage, count: Int, total: Int, timestamp: Int, latitude: Double?, longitude: Double?, isFavorite: Bool) {
        let url = URL(string: DEV_UPLOAD_URL)!
        
        // Get request ready
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let imgBase64 = img.pngData()?.base64EncodedString()
        let jsonObj: [String: Any?] = [
            "a": albumField.text ?? DEFAULT_ALBUM_NAME, // second part of relative path on server
            "p": HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": imgBase64,  // image data

            "u": user,  // user name, used as first path of relative path on server where photos will be stored
            "t": timestamp,
            "lat": latitude,
            "long": longitude,
            "f": isFavorite,
        ]
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: [])
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                if error == nil && (response as! HTTPURLResponse).statusCode == 200 {
                    print ("Successful upload!")
                    self.statusMessage.text = self.UPLOADED_IMAGE_MSG.replacingOccurrences(of: "{total}", with: String(total)).replacingOccurrences(of: "{number}", with: String(count))
                } else {
                    print ("Upload failed.")
                    print ("  Error:", error ?? "nil error")
                    self.failedUploadCount += 1
                    self.statusMessage.text = self.UPLOAD_FAILED_MSG.replacingOccurrences(of: "{total}", with: String(total)).replacingOccurrences(of: "{number}", with: String(count))
                }
                if (count == total) {
                    if (self.failedUploadCount > 0) {
                        self.statusMessage.text = self.SOME_UPLOADS_FAILED.replacingOccurrences(of: "{total}", with: String(self.results!.count)).replacingOccurrences(of: "{number}", with: String(self.failedUploadCount))
                    } else {
                        self.statusMessage.text = self.UPLOAD_FINISHED_MSG
                    }
                }
            }
        }).resume()
    }
}

// Handlers for buttons
extension ViewController {
    @IBAction func findNewPhotosHandler(_ sender: Any, forEvent event: UIEvent) {
        getPhotos()
    }
    
    @IBAction func findNewVideosHandler(_ sender: UIButton, forEvent event: UIEvent) {
        // getVideos()
    }
    
    @IBAction func uploadHandler(_ sender: UIButton, forEvent event: UIEvent) {
        DispatchQueue.global(qos: .background).async {
            self.startUpload()
        }
    }
}
