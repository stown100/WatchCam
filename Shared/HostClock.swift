import Darwin

/// Monotonic host clock in seconds (`mach_absolute_time`).
///
/// AVFoundation timestamps (AVAudioTime.hostTime, capture PTS) use the same clock,
/// so every timing value exchanged between the apps is expressed in it.
enum HostClock {
    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func now() -> Double {
        seconds(fromTicks: mach_absolute_time())
    }

    static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * ticksToSeconds
    }
}
