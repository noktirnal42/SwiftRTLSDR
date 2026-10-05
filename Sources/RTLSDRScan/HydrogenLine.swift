// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The 21 cm line of neutral hydrogen, and the velocities radio astronomers quote it in.
public enum HydrogenLine {
    /// Rest frequency of the hyperfine transition, hertz.
    public static let restHz = 1_420_405_751.768
    public static let speedOfLightKMS = 299_792.458

    /// Radio-convention velocity of gas emitting at `frequencyHz` as received: c (f₀ − f) / f₀, km/s, positive receding.
    public static func radioVelocity(frequencyHz: Double) -> Double {
        speedOfLightKMS * (restHz - frequencyHz) / restHz
    }
}

/// The velocity to add to a velocity measured at an antenna to refer it to the local standard of rest (the kinematic
/// LSR: the Sun moving at 20 km/s toward RA 18h, Dec +30° of 1900), to about 0.3 km/s.
///
/// Three motions are projected onto the line of sight: the Earth's orbit (from the low-precision solar position of the
/// Astronomical Almanac, differentiated), its rotation, and the Sun's motion. Coordinates are J2000; the precession
/// since then moves the result by under 0.2 km/s.
public enum LSRCorrection {
    /// The correction, km/s, for a source at (`rightAscension` hours, `declination` degrees) seen at `date` from
    /// `latitude`, `longitude` (degrees, east positive).
    public static func velocity(rightAscension: Double, declination: Double, date: Date, latitude: Double, longitude: Double) -> Double {
        let source = unit(rightAscension: rightAscension * 15, declination: declination)
        let orbit = earthOrbitalVelocity(date)
        let lst = localSiderealDegrees(date, longitude: longitude) * .pi / 180
        let rotation = 0.465_1 * cos(latitude * .pi / 180)                     // km/s eastward at the equator × cos(lat)
        let spin = [-sin(lst) * rotation, cos(lst) * rotation, 0.0]
        let apex = unit(rightAscension: 270.959_39, declination: 30.004_67)     // 18h, +30° of B1900, in J2000
        let sun = apex.map { $0 * 20 }
        var total = 0.0
        for axis in 0..<3 {
            let motion: Double = orbit[axis] + spin[axis] + sun[axis]
            total += motion * source[axis]
        }
        return total
    }

    /// J2000 right ascension (hours) and declination (degrees) of where an antenna at azimuth `azimuth` (degrees from
    /// north through east) and elevation `elevation` points (no refraction: it is under a tenth of a degree above 20°).
    public static func equatorial(azimuth: Double, elevation: Double, date: Date, latitude: Double, longitude: Double)
        -> (rightAscension: Double, declination: Double) {
        let a = azimuth * .pi / 180, h = elevation * .pi / 180, phi = latitude * .pi / 180
        let dec = asin(sin(phi) * sin(h) + cos(phi) * cos(h) * cos(a))
        let hourAngle = atan2(-sin(a) * cos(h), cos(phi) * sin(h) - sin(phi) * cos(h) * cos(a))
        let ra = (localSiderealDegrees(date, longitude: longitude) - hourAngle * 180 / .pi) * .pi / 180
        // Back from the equinox of date to J2000: the annual precession in RA is m + n sin α tan δ, in declination
        // n cos α (m = 46.12″, n = 20.04″).
        let years = days(date) / 365.25
        let m = 46.12 / 3600 * .pi / 180, n = 20.04 / 3600 * .pi / 180
        let raJ2000 = ra - years * (m + n * sin(ra) * tan(dec))
        let decJ2000 = dec - years * n * cos(ra)
        var hours = raJ2000 * 12 / .pi
        hours = (hours.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        return (hours, decJ2000 * 180 / .pi)
    }

    /// Days since J2000.0 (2000-01-01 12:00 UTC; the few seconds of TT − UTC do not matter here).
    static func days(_ date: Date) -> Double { (date.timeIntervalSince1970 - 946_728_000) / 86_400 }

    static func localSiderealDegrees(_ date: Date, longitude: Double) -> Double {
        let gmst = 280.460_618_37 + 360.985_647_366_29 * days(date)
        return ((gmst + longitude).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    static func unit(rightAscension: Double, declination: Double) -> [Double] {
        let a = rightAscension * .pi / 180, d = declination * .pi / 180
        return [cos(d) * cos(a), cos(d) * sin(a), sin(d)]
    }

    /// The Sun's geocentric position (equatorial, AU) by the Almanac's low-precision formulas.
    static func sunPosition(days n: Double) -> [Double] {
        let g = (357.528 + 0.985_600_3 * n) * .pi / 180
        let l = (280.460 + 0.985_647_4 * n + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let r = 1.000_14 - 0.016_71 * cos(g) - 0.000_14 * cos(2 * g)
        let e = (23.439 - 0.000_000_4 * n) * .pi / 180
        return [r * cos(l), r * cos(e) * sin(l), r * sin(e) * sin(l)]
    }

    /// The Earth's velocity about the Sun (equatorial, km/s): minus the Sun's apparent motion.
    static func earthOrbitalVelocity(_ date: Date) -> [Double] {
        let n = days(date), step = 0.05
        let before = sunPosition(days: n - step), after = sunPosition(days: n + step)
        let kmPerAUPerDay = 149_597_870.7 / 86_400
        return (0..<3).map { -(after[$0] - before[$0]) / (2 * step) * kmPerAUPerDay }
    }
}

/// Long-integration power spectra taken in two tunings, the signal and a reference (frequency switching): their
/// ratio divides out the dongle's bandpass and gain, leaving what only the signal tuning sees, such as a 21 cm line.
public final class SwitchedSpectrometer {
    public enum Position: Sendable { case signal, reference }

    public let fftSize: Int
    public let sampleRate: Double
    private let estimator: SpectrumEstimator
    public private(set) var signal: [Double]
    public private(set) var reference: [Double]
    public private(set) var signalTransforms = 0
    public private(set) var referenceTransforms = 0

    public init?(fftSize: Int, sampleRate: Double) {
        guard let estimator = SpectrumEstimator(fftSize: fftSize) else { return nil }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.estimator = estimator
        signal = [Double](repeating: 0, count: fftSize)
        reference = signal
    }

    /// Adds u8 I/Q taken in `position` (whole transforms only; the remainder of a block is dropped).
    public func add(_ iq: [UInt8], to position: Position) {
        let frames = estimator.frames(inByteCount: iq.count)
        guard frames > 0, let power = estimator.averagePower(iq) else { return }
        switch position {
        case .signal:
            for k in 0..<fftSize { signal[k] += power[k] * Double(frames) }
            signalTransforms += frames
        case .reference:
            for k in 0..<fftSize { reference[k] += power[k] * Double(frames) }
            referenceTransforms += frames
        }
    }

    /// Seconds of samples integrated in each position.
    public var integratedSeconds: (signal: Double, reference: Double) {
        (Double(signalTransforms * fftSize) / sampleRate, Double(referenceTransforms * fftSize) / sampleRate)
    }

    /// Offset of each bin from the tuned frequency (DC in the middle), hertz.
    public var binOffsets: [Double] { (0..<fftSize).map { Double($0 - fftSize / 2) * sampleRate / Double(fftSize) } }

    /// Signal over reference, minus one, each averaged over `smoothing` bins; the `blank` bins either side of DC (the
    /// dongle's spike) are bridged by a straight line. nil until both positions have data.
    public func ratio(smoothing: Int = 1, blank: Int = 2) -> [Double]? {
        guard signalTransforms > 0, referenceTransforms > 0 else { return nil }
        let s = Double(signalTransforms), r = Double(referenceTransforms)
        var values = (0..<fftSize).map { k in reference[k] > 0 ? (signal[k] / s) / (reference[k] / r) - 1 : 0 }
        let mid = fftSize / 2
        if blank > 0, mid - blank - 1 >= 0, mid + blank + 1 < fftSize {
            let left = values[mid - blank - 1], right = values[mid + blank + 1]
            for k in (mid - blank)...(mid + blank) {
                values[k] = left + (right - left) * Double(k - (mid - blank - 1)) / Double(2 * blank + 2)
            }
        }
        guard smoothing > 1 else { return values }
        return (0..<fftSize).map { k in
            let low = max(0, k - smoothing / 2), high = min(fftSize, low + smoothing)
            return values[low..<high].reduce(0, +) / Double(high - low)
        }
    }
}
