import ColorSync
import CoreGraphics
import Foundation
// cs info <displayID> | cs set <displayID> <iccPath|factory>
let a = CommandLine.arguments
let did = CGDirectDisplayID(UInt32(a[2])!)
let uuid = CGDisplayCreateUUIDFromDisplayID(did)!.takeRetainedValue()
if a[1] == "info" {
  let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)!.takeRetainedValue() as NSDictionary
  print(info)
} else if a[1] == "set" {
  let value: Any = a[3] == "factory" ? kCFNull as Any : URL(fileURLWithPath: a[3]) as NSURL
  let profiles: NSDictionary = [a[4]: value]
  let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, profiles)
  print("set ok=\(ok)")
}
