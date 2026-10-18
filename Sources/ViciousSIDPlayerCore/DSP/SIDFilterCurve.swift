import Foundation

enum SIDFilterCurve {
    static func coefficients6581(sampleRate: Double) -> [Double] {
        let referenceRate = 44100.0
        let referenceRatio = -2.0 * .pi * (20000.0 / 256.0) / referenceRate
        return (0..<2048).map { register in
            let cutoff = Double(register) / 8.0 + 0.2
            let reference = cutoff < 24.0 ? 0.035 : 1.0 - 1.263 * exp(cutoff * referenceRatio)
            // Die freigegebene 44,1-kHz-Kurve bleibt exakt erhalten. Andere
            // Raten übernehmen ihre Integrator-Zeitkonstante; kein Chipmodell-Port.
            return sampleRate == referenceRate ? reference : 1.0 - pow(1.0 - reference, referenceRate / sampleRate)
        }
    }
}
