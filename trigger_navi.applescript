tell application "System Events"
    do shell script "swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: NSNotification.Name(\"NaviTaskComplete\"), object: nil)'"
end tell
