//
//  PlatformImage.swift
//  BetterContentCore
//
//  A single image type the shared controller layer can use on both platforms:
//  NSImage on macOS, UIImage on iOS. The thumbnail/skim code only needs to
//  decode JPEG data and wrap CGImages, both of which differ only slightly
//  between AppKit and UIKit.
//

import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// Wraps a `CGImage` in the platform image type at its native pixel size.
    static func from(cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
