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
// Added some buttons to UI for looking for photos, videos. The status message doesn't update correctly, probably
// bc of some main thread blocking shit

class ViewController: UIViewController {
    
    @IBOutlet weak var statusMessage: UILabel!
    
    var images = [UIImage]()
    var results: PHFetchResult<PHAsset>?
    var failedUploadCount: Int = 0
    
    var user: String = "vicky"
    var album: String = "default"
    
    let WELCOME_MSG = "Click the buttons below to get started!"
    let FOUND_IMAGES_MSG = "Found {total} images that have not been uploaded to vingilot. Press Upload to upload them."
    let STARTING_UPLOAD = "Starting upload."
    let UPLOADED_IMAGE_MSG = "Uploaded image {number} of {total}!"
    let UPLOAD_FINISHED_MSG = "Uploads completed successfully. Double check Plex for the uploaded images. If they're there, you can delete photos from your phone."
    let SOME_UPLOADS_FAILED = "{number} of {total} uploads FAILED. Exercise caution when you delete images from your phone; some didn't make it onto the backup server!"
    let UPLOAD_FAILED_MSG = "Upload FAILED for image {number} of {total}!"

    let DEV_UPLOAD_URL = "http://0.0.0.0:9090/image"
    let DEV_CHECK_URL = "http://0.0.0.0:9090/check"
    let PROD_UPLOAD_URL = "http://vingilot:9090/image"
    let PROD_CHECK_URL = "http://0.0.0.0:9090/check"
    
    let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"

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
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: requestOptions) { (img, info) in
                self.upload(img: img!, count: i + 1, total: self.results!.count)
            }
        }
    }
    
    func upload(img: UIImage, count: Int, total: Int) {
        let url = URL(string: DEV_UPLOAD_URL)!
        
        // Get request ready
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: url)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let imgBase64 = img.pngData()?.base64EncodedString()
        let jsonObj: [String: Any] = [
            "i": imgBase64 ?? "null",  // image data
            "d": user,  // user name, used as first path of relative path on server where photos will be stored
            "a": album, // album name, used as second part of relative path on server
            "l": HARD_CODED_PASSWORD_HOW_SHAMEFUL,
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