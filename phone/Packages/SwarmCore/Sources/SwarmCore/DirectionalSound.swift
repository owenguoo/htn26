import Foundation

/// A short, loud acoustic event located relative to the phone's screen.
/// Negative bearings are left, positive bearings are right, and zero is ahead.
public struct DirectionalSoundEvent: Sendable, Equatable {
    public var relativeBearingDegrees: Double
    public var confidence: Double

    public init(relativeBearingDegrees: Double, confidence: Double) {
        self.relativeBearingDegrees = relativeBearingDegrees
        self.confidence = confidence
    }
}

/// Finds impulse-like sounds in stereo PCM and estimates a coarse left/right
/// bearing from inter-channel level difference (ILD).
///
/// The detector deliberately waits for the sound to decay before emitting. A
/// bang is short; speech and room noise tend to remain above the onset
/// threshold. This makes the detector useful beside the voice gate without
/// exposing audio outside the native client.
public struct DirectionalSoundDetector: Sendable {
    private struct Candidate: Sendable {
        var startedAt: Double
        var weightedBalance: Double
        var totalWeight: Double
        var peakLevel: Double
    }

    private var noiseFloor = 0.015
    private var candidate: Candidate?
    private var rejectingSustainedSound = false
    private var suppressedUntil = -Double.infinity
    private var cooldownUntil = -Double.infinity

    /// Absolute floor keeps ordinary speech at arm's length from constantly
    /// opening the detector; the adaptive multiplier follows a noisy venue.
    public static let minimumOnsetRMS = 0.08
    public static let noiseMultiplier = 4.0
    public static let maximumBurstDuration = 0.45
    public static let cooldown = 0.8

    public init() {}

    /// Ignore capture through a known locally-generated sound (ping/message).
    public mutating func suppress(until: Double) {
        suppressedUntil = max(suppressedUntil, until)
        candidate = nil
        rejectingSustainedSound = false
    }

    /// Mono routes still feed voice, but cannot produce a direction cue.
    public mutating func offerMono(_ samples: [Float], at time: Double) -> DirectionalSoundEvent? {
        updateNoiseFloor(with: Self.rms(samples))
        if time >= suppressedUntil { candidate = nil }
        return nil
    }

    /// Offers one pair of time-aligned, non-interleaved stereo channels.
    public mutating func offerStereo(left: [Float], right: [Float],
                                     at time: Double) -> DirectionalSoundEvent? {
        guard !left.isEmpty, left.count == right.count else { return nil }

        let leftRMS = Self.rms(left)
        let rightRMS = Self.rms(right)
        let level = sqrt((leftRMS * leftRMS + rightRMS * rightRMS) / 2)
        let onset = max(Self.minimumOnsetRMS, noiseFloor * Self.noiseMultiplier)
        let isLoud = level >= onset

        guard time >= suppressedUntil else {
            candidate = nil
            if !isLoud { updateNoiseFloor(with: level) }
            return nil
        }

        if rejectingSustainedSound {
            if !isLoud {
                rejectingSustainedSound = false
                updateNoiseFloor(with: level)
            }
            return nil
        }

        if var active = candidate {
            if time - active.startedAt > Self.maximumBurstDuration {
                candidate = nil
                rejectingSustainedSound = true
                return nil
            }
            if isLoud {
                Self.accumulate(leftRMS: leftRMS, rightRMS: rightRMS, level: level, into: &active)
                candidate = active
                return nil
            }

            candidate = nil
            updateNoiseFloor(with: level)
            guard time >= cooldownUntil, active.totalWeight > 0 else { return nil }
            cooldownUntil = time + Self.cooldown
            let balance = max(-1, min(1, active.weightedBalance / active.totalWeight))
            let directionalConfidence = abs(balance)
            let strengthConfidence = min(1, active.peakLevel / (onset * 2))
            return DirectionalSoundEvent(
                relativeBearingDegrees: balance * 90,
                confidence: max(0.2, directionalConfidence * strengthConfidence)
            )
        }

        guard isLoud, time >= cooldownUntil else {
            updateNoiseFloor(with: level)
            return nil
        }
        var active = Candidate(startedAt: time, weightedBalance: 0, totalWeight: 0, peakLevel: level)
        Self.accumulate(leftRMS: leftRMS, rightRMS: rightRMS, level: level, into: &active)
        candidate = active
        return nil
    }

    private mutating func updateNoiseFloor(with level: Double) {
        guard level.isFinite else { return }
        noiseFloor = max(0.002, noiseFloor * 0.97 + min(level, 0.08) * 0.03)
    }

    private static func accumulate(leftRMS: Double, rightRMS: Double, level: Double,
                                   into candidate: inout Candidate) {
        let sum = leftRMS + rightRMS
        let balance = sum > 1e-9 ? (rightRMS - leftRMS) / sum : 0
        candidate.weightedBalance += balance * level
        candidate.totalWeight += level
        candidate.peakLevel = max(candidate.peakLevel, level)
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(into: 0.0) { total, sample in
            let value = Double(sample)
            total += value * value
        }
        return sqrt(sum / Double(samples.count))
    }
}
