import Foundation

@objc public protocol ChargeDaemonProtocol {
    func status(reply: @escaping (NSDictionary) -> Void)
    func setLimits(minCharge: Int, maxCharge: Int, reply: @escaping (Bool) -> Void)
    func setMode(_ mode: String, reply: @escaping (Bool) -> Void)
}

public enum ChargeMode: String {
    case normal
    case chargeFull
    case dischargeToLimit
}

public enum ChargeLimits {
    public static let minimum = 50
    public static let maximum = 100

    public static func isValid(minCharge: Int, maxCharge: Int) -> Bool {
        minCharge >= minimum && minCharge < maxCharge && maxCharge <= maximum
    }
}

public enum DaemonMachService {
    public static let name = "RQ92NCNQPL.com.nvksie.chargelmt.daemon"
}
