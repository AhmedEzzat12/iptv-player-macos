import Foundation

/// Second-order IIR filter coefficients, normalised so a0 = 1 (RBJ "Audio EQ Cookbook" designs). FFmpeg's
/// `equalizer` filter uses the same peaking design, so the mpv and AVFoundation paths share their EQ curves.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passes the signal through unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Peaking EQ: `gainDB` at `frequency`, bandwidth set by `q`, unity gain far from it.
    public static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2, q > 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return BiquadCoefficients(b0: (1 + alpha * a) / a0, b1: -2 * cosW0 / a0, b2: (1 - alpha * a) / a0,
                                  a1: -2 * cosW0 / a0, a2: (1 - alpha / a) / a0)
    }

    /// Linear magnitude of the frequency response at `frequency`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        return sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
    }
}

/// One biquad's running state (transposed direct form II, double precision). Allocation-free.
public struct BiquadFilter: Sendable {
    public var coefficients: BiquadCoefficients
    private var z1 = 0.0
    private var z2 = 0.0

    public init(_ coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        // Flush denormals once the input goes silent.
        if abs(z1) < 1e-25 { z1 = 0 }
        if abs(z2) < 1e-25 { z2 = 0 }
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
