//
//  Util.swift
//  sumubackup
//
//  Created by Hamik on 4/5/20.
//  Copyright © 2020 Sumu. All rights reserved.
//

import Foundation
import Photos

class Utilities: NSObject {

    // Used for sha256 methods on Data and UIImage
    static func Digest(input : NSData) -> NSData {
        let digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        var hash = [UInt8](repeating: 0, count: digestLength)
        CC_SHA256(input.bytes, UInt32(input.length), &hash)
        return NSData(bytes: hash, length: digestLength)
    }

    // Used for sha256 methods on Data and UIImage
    static func HexStringFromData(input: NSData) -> String {
        var bytes = [UInt8](repeating: 0, count: input.length)
        input.getBytes(&bytes, length: input.length)

        var hexString = ""
        for byte in bytes {
            hexString += String(format:"%02x", UInt8(byte))
        }

        return hexString
    }

    // This method returns the index of the first timestamp in the sorted keys of uploadCompleteIfRequired such that some of its assets failed to asset
    static func SupremumOfContiguousSuccessfulUploadIndices(within uploadCompleteIfRequired: [UInt64: [Bool]]) -> Int {
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
    static func GetNextAvailableTimestamp(from startingTimestamp: UInt64, offset: Int, within timestampToAssetList: [UInt64: [PHAsset]]) -> UInt64 {
        if offset == 0 {
            return startingTimestamp
        }
        var candidateTimestamp = GetNextAvailableTimestamp(from: startingTimestamp, offset: offset - 1, within: timestampToAssetList) + 1
        let currentTimestamps = timestampToAssetList.keys
        while currentTimestamps.contains(candidateTimestamp) {
            candidateTimestamp += 1
        }
        return candidateTimestamp
    }

    // Used to track image upload number
    static func GetCumulativeAssetsBeforeTimestamp(within timestampToAssetList: [UInt64: [PHAsset]], sortedKeys: [UInt64]) -> [UInt64: Int] {
        var ret: [UInt64: Int] = [:]
        for i in 0..<sortedKeys.count {
            let currentTimestamp = sortedKeys[i]
            if i == 0 {
                ret[currentTimestamp] = 0
                continue
            }
            let previousTimestamp = sortedKeys[i - 1]
            let previousArray = timestampToAssetList[previousTimestamp]!
            ret[currentTimestamp] = ret[previousTimestamp]! + previousArray.count
        }
        return ret
    }

    static func GetNumFailedUploads(within uploadCompleteIfRequired: [UInt64: [Bool]]) -> Int {
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
}
