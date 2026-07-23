import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let requestedPID = Int32(CommandLine.arguments[1]),
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]] else {
    exit(2)
}

let match = windows.first { window in
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int32
    let layer = window[kCGWindowLayer as String] as? Int
    let alpha = window[kCGWindowAlpha as String] as? Double
    return ownerPID == requestedPID && layer == 0 && (alpha ?? 0) > 0
}

guard let number = match?[kCGWindowNumber as String] as? UInt32 else {
    exit(1)
}
print(number)
