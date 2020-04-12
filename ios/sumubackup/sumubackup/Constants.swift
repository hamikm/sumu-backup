//
//  Constants.swift
//  sumubackup
//
//  Created by Hamik on 4/12/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import Foundation
import UIKit

class Constants: NSObject {

    static let SERVER = "vingilot"
    static let HEALTH_URL = "http://\(SERVER):9090/health"
    static let TIMESTAMPS_URL = "http://\(SERVER):9090/timestamps"
    static let PART_URL = "http://\(SERVER):9090/part"
    static let SAVE_URL = "http://\(SERVER):9090/save"
    static let HARD_CODED_PASSWORD_HOW_SHAMEFUL = "beeblesissuchameerkat"
    static let DEFAULT_ALBUM_NAME = "default"
    static let RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS = DispatchTimeInterval.seconds(5)
    static let JPEG_COMPRESSION_QUALITY = CGFloat(1)

    // Status message constants
    static let CHECKING_SERVER_MSG = "Checking if \(SERVER) is online..."
    static let SERVER_OFFLINE_MSG = "\(SERVER) is offline."
    static let PREPARING_UPLOAD = "Preparing upload..."
    static let WELCOME_MSG = "Upload iPhone media to \(SERVER)!"
    static let UPLOADING_MEDIA_MSG = { (type: String, number: Int, total: Int) in "Uploading \(type) \(String(number)) of \(String(total))..." }
    static let UPLOADS_FINISHED_MSG = { (type: String) in "Uploads finished. Check Plex for your \(type); if they're there, you can delete them from your phone." }
    static let SOME_UPLOADS_FAILED_MSG = { (type: String, number: Int, total: Int) in "\(String(number)) of \(String(total)) uploads failed. Careful when you delete \(type) from your phone!" }
    static let FINAL_DUPLICATES_MSG = { (type: String, numAlreadyOnBackend: Int) in "Did not upload \(String(numAlreadyOnBackend)) \(type) because they were already on \(SERVER)." }
    static let DUPLICATE_MSG =  { (type: String, number: Int, total: Int) in "\(type) \(String(number)) of \(String(total)) is already on the server!" }
    static let UPLOAD_INTERRUPTED_MSG = "Lost connection to \(SERVER) while uploading. Retrying..."
}
