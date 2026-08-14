import Foundation

public enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, min, max, custom
    public var id: String { rawValue }
    public var localizedKey: String {
        switch self {
        case .auto: return "mode.auto"
        case .min: return "mode.min"
        case .max: return "mode.max"
        case .custom: return "mode.custom"
        }
    }
}

public struct FanInfo: Equatable {
    public let index: Int
    public var currentRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public init(index: Int, currentRPM: Double, minRPM: Double, maxRPM: Double) {
        self.index = index
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public enum FanWriteAction: Equatable {
    case auto
    case manual(Double)
}

public protocol FanReading {
    func refreshFans() throws -> [FanInfo]
    func cpuTemperature() throws -> Double?
}

public protocol FanWriting {
    func write(_ action: FanWriteAction, index: Int) throws
}
