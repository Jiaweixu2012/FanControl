import Foundation
import Combine

/// App-facing controller. `reader` = direct SMC (user context, reads OK).
/// `writer` = root helper for the app (socket) or direct SMC inside the daemon.
public final class FanController: ObservableObject {

    @Published public var mode: FanMode = .auto
    @Published public var customRPM: String = "2000"
    @Published public var fans: [FanInfo] = []
    @Published public var cpuTemp: Double?
    @Published public var errorMessage: String?

    public let reader: FanReading
    public let writer: FanWriting

    public init(reader: FanReading, writer: FanWriting) {
        self.reader = reader
        self.writer = writer
    }

    public func refresh() {
        if let fans = try? reader.refreshFans() { self.fans = fans }
        cpuTemp = (try? reader.cpuTemperature()) ?? nil
    }

    public func applyMode() throws {
        errorMessage = nil
        let fans = (try? reader.refreshFans()) ?? self.fans
        for fan in fans {
            do {
                try applyMode(to: fan, fans: fans)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyMode(to fan: FanInfo, fans: [FanInfo]) throws {
        switch mode {
        case .auto:
            try writer.write(.auto, index: fan.index)
        case .min:
            try writer.write(.manual(fan.minRPM), index: fan.index)
        case .max:
            try writer.write(.manual(fan.maxRPM), index: fan.index)
        case .custom:
            guard let rpm = validatedCustomRPM(fans: fans) else { return }
            let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
            try writer.write(.manual(clamped), index: fan.index)
        }
    }

    /// Global validation range: min of mins .. max of maxs
    public func isValidCustomRPM(_ text: String, fans: [FanInfo]) -> Bool {
        guard let rpm = Double(text) else { return false }
        let lo = fans.map(\.minRPM).min() ?? 0
        let hi = fans.map(\.maxRPM).max() ?? 0
        return rpm >= lo && rpm <= hi
    }

    public func validatedCustomRPM(fans: [FanInfo]) -> Double? {
        guard isValidCustomRPM(customRPM, fans: fans) else {
            let lo = fans.map(\.minRPM).min() ?? 0
            let hi = fans.map(\.maxRPM).max() ?? 0
            errorMessage = "RPM must be between \(Int(lo)) and \(Int(hi))"
            return nil
        }
        return Double(customRPM)
    }

    public func applyCustomIfNeeded() throws {
        if mode == .custom { try applyMode() }
    }
}
