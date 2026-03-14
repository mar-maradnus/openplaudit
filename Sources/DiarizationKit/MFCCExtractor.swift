/// MFCC feature extraction using Accelerate framework.
///
/// Computes Mel-Frequency Cepstral Coefficients from 16kHz mono PCM audio.
/// Used by the clustering-based diarization backend for speaker embeddings.

import Accelerate
import Foundation

/// MFCC extraction parameters.
struct MFCCConfig {
    let sampleRate: Double = 16000
    let frameLength: Int = 400     // 25ms at 16kHz
    let frameStep: Int = 160       // 10ms hop
    let fftSize: Int = 512
    let numMelBands: Int = 40
    let numCoeffs: Int = 13
    let preEmphasis: Float = 0.97
}

/// Extract MFCC features from 16kHz mono Float32 audio samples.
///
/// Returns a 2D array: [numFrames][numCoeffs].
func extractMFCC(samples: [Float], config: MFCCConfig = MFCCConfig()) -> [[Float]] {
    guard samples.count > config.frameLength else { return [] }

    // Pre-emphasis filter
    var emphasized = [Float](repeating: 0, count: samples.count)
    emphasized[0] = samples[0]
    for i in 1..<samples.count {
        emphasized[i] = samples[i] - config.preEmphasis * samples[i - 1]
    }

    // Frame the signal
    let numFrames = (emphasized.count - config.frameLength) / config.frameStep + 1
    guard numFrames > 0 else { return [] }

    // Hamming window
    let window = hammingWindow(size: config.frameLength)

    // Mel filter bank
    let melFilters = melFilterBank(
        numFilters: config.numMelBands,
        fftSize: config.fftSize,
        sampleRate: config.sampleRate
    )

    var mfccs = [[Float]]()
    mfccs.reserveCapacity(numFrames)

    for frameIdx in 0..<numFrames {
        let start = frameIdx * config.frameStep

        // Window the frame
        var frame = [Float](repeating: 0, count: config.fftSize)
        for i in 0..<config.frameLength {
            frame[i] = emphasized[start + i] * window[i]
        }

        // FFT → power spectrum
        let powerSpectrum = computePowerSpectrum(frame: frame, fftSize: config.fftSize)

        // Apply mel filters
        var melEnergies = [Float](repeating: 0, count: config.numMelBands)
        for m in 0..<config.numMelBands {
            var sum: Float = 0
            let specSize = min(powerSpectrum.count, melFilters[m].count)
            for k in 0..<specSize {
                sum += powerSpectrum[k] * melFilters[m][k]
            }
            melEnergies[m] = max(sum, 1e-10)
        }

        // Log mel energies
        for m in 0..<config.numMelBands {
            melEnergies[m] = log(melEnergies[m])
        }

        // DCT to get MFCCs
        let coeffs = dctII(melEnergies, numCoeffs: config.numCoeffs)
        mfccs.append(coeffs)
    }

    return mfccs
}

// MARK: - DSP Helpers

func hammingWindow(size: Int) -> [Float] {
    (0..<size).map { i in
        0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(size - 1))
    }
}

func computePowerSpectrum(frame: [Float], fftSize: Int) -> [Float] {
    let log2n = vDSP_Length(log2(Double(fftSize)))
    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    let halfN = fftSize / 2
    var real = [Float](repeating: 0, count: halfN)
    var imag = [Float](repeating: 0, count: halfN)

    // Pack into split complex
    frame.withUnsafeBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
            var split = DSPSplitComplex(realp: &real, imagp: &imag)
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
        }
    }

    // Forward FFT
    var split = DSPSplitComplex(realp: &real, imagp: &imag)
    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

    // Power spectrum
    var power = [Float](repeating: 0, count: halfN)
    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))

    // Normalize
    var scale: Float = 1.0 / Float(fftSize * fftSize)
    vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(halfN))

    return power
}

func melFilterBank(numFilters: Int, fftSize: Int, sampleRate: Double) -> [[Float]] {
    let halfFFT = fftSize / 2
    let lowMel = hzToMel(0)
    let highMel = hzToMel(sampleRate / 2)

    // Evenly spaced mel points
    let melPoints = (0...(numFilters + 1)).map { i in
        lowMel + (highMel - lowMel) * Double(i) / Double(numFilters + 1)
    }
    let hzPoints = melPoints.map { melToHz($0) }
    let binPoints = hzPoints.map { Int(($0 / sampleRate * Double(fftSize)).rounded()) }

    var filters = [[Float]](repeating: [Float](repeating: 0, count: halfFFT), count: numFilters)
    for m in 0..<numFilters {
        let left = binPoints[m]
        let center = binPoints[m + 1]
        let right = binPoints[m + 2]

        for k in left..<center where k < halfFFT {
            filters[m][k] = Float(k - left) / Float(max(center - left, 1))
        }
        for k in center..<right where k < halfFFT {
            filters[m][k] = Float(right - k) / Float(max(right - center, 1))
        }
    }
    return filters
}

func dctII(_ input: [Float], numCoeffs: Int) -> [Float] {
    let N = input.count
    return (0..<numCoeffs).map { k in
        var sum: Float = 0
        for n in 0..<N {
            sum += input[n] * cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(N))
        }
        return sum
    }
}

func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }
