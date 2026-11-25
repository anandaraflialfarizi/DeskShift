import Foundation

public enum PairingHandoff {
    public static let activityType = "local.padbridge.pair"

    public static func makeActivity(for code: PairingCode, now: Date = .now) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        let expires = now.addingTimeInterval(120)
        activity.title = "Sambungkan PadBridge ke Mac"
        activity.userInfo = ["pairing-code": code.text, "expires": expires]
        activity.requiredUserInfoKeys = ["pairing-code", "expires"]
        activity.expirationDate = expires
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        return activity
    }

    public static func read(_ activity: NSUserActivity, now: Date = .now) throws -> PairingCode {
        guard activity.activityType == activityType,
              let expires = activity.userInfo?["expires"] as? Date, expires > now,
              let code = activity.userInfo?["pairing-code"] as? String else {
            throw ProtocolError.invalidPacket
        }
        return try PairingCode(code)
    }
}
