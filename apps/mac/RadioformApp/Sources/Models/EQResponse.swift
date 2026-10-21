import Foundation

/// Frequency response of the EQ, computed with the same biquad math as the DSP
/// engine (packages/dsp/src/biquad.h) so the curve drawn in the UI is the curve you hear.
enum EQResponse {
    /// Reference rate for drawing. The host runs at the device rate, which only
    /// changes the curve noticeably right next to Nyquist.
    static let sampleRate: Double = 48000

    struct Coeffs {
        var b0, b1, b2, a1, a2: Double
    }

    static func coefficients(
        frequencyHz: Float,
        gainDb: Float,
        q: Float,
        type: FilterType,
        sampleRate: Double = sampleRate
    ) -> Coeffs {
        let w0 = 2.0 * Double.pi * Double(frequencyHz) / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let Q = Double(q)

        // Same bandwidth prewarp as the engine
        let warp = w0 < 0.01 ? 1.0 : w0 / sinW0
        let alpha = sinW0 / (2.0 * Q * warp)
        let A = pow(10.0, Double(gainDb) / 40.0)

        let b0, b1, b2, a0, a1, a2: Double
        switch type {
        case .peak:
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A
        case .lowShelf:
            let beta = A.squareRoot() / Q
            b0 = A * ((A + 1) - (A - 1) * cosW0 + beta * sinW0)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - beta * sinW0)
            a0 = (A + 1) + (A - 1) * cosW0 + beta * sinW0
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - beta * sinW0
        case .highShelf:
            let beta = A.squareRoot() / Q
            b0 = A * ((A + 1) + (A - 1) * cosW0 + beta * sinW0)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - beta * sinW0)
            a0 = (A + 1) - (A - 1) * cosW0 + beta * sinW0
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - beta * sinW0
        case .lowPass:
            b0 = (1 - cosW0) / 2
            b1 = 1 - cosW0
            b2 = (1 - cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosW0) / 2
            b1 = -(1 + cosW0)
            b2 = (1 + cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        case .notch:
            b0 = 1
            b1 = -2 * cosW0
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        case .bandPass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        }

        return Coeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude of H(e^jw) in dB at the given frequency
    static func magnitudeDb(_ c: Coeffs, at frequencyHz: Double, sampleRate: Double = sampleRate) -> Double {
        let w = 2.0 * Double.pi * frequencyHz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)

        let numRe = c.b0 + c.b1 * cos1 + c.b2 * cos2
        let numIm = -(c.b1 * sin1 + c.b2 * sin2)
        let denRe = 1 + c.a1 * cos1 + c.a2 * cos2
        let denIm = -(c.a1 * sin1 + c.a2 * sin2)

        let num = numRe * numRe + numIm * numIm
        let den = denRe * denRe + denIm * denIm
        guard num > 0, den > 0 else { return -120 }
        return 10 * log10(num / den)
    }
}
