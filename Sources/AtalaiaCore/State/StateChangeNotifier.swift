import CoreFoundation

public enum StateChangeNotifier {
    public static let notificationName = "com.atalaia.stateChanged"

    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
