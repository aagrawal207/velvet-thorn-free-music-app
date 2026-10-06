import AudioToolbox
import Foundation

/// "Dha, ti, na": three tabla-like strokes synthesized in code (no recorded audio), as 16-bit mono PCM WAV.
/// Each stroke is a few decaying harmonics whose pitch drops quickly after the strike, plus a short click.
enum TablaFlourish {
    static let sampleRate = 22_050
    /// Versioned, so a change to the synthesis writes a new file instead of replaying an old one.
    static let fileName = "tabla-flourish-1.wav"

    private struct Stroke {
        let onset: TimeInterval
        let pitch: Double
        /// Starting pitch as a multiple of `pitch`; it falls to 1 within a few tens of milliseconds.
        let drop: Double
        let decay: Double
        let length: TimeInterval
        let level: Double
        let bass: Double?
    }

    private static let strokes = [
        Stroke(onset: 0, pitch: 330, drop: 1.3, decay: 9, length: 0.32, level: 0.9, bass: 98),
        Stroke(onset: 0.17, pitch: 880, drop: 1.2, decay: 30, length: 0.12, level: 0.55, bass: nil),
        Stroke(onset: 0.29, pitch: 523, drop: 1.28, decay: 7.5, length: 0.38, level: 0.8, bass: nil),
    ]

    static var duration: TimeInterval { strokes.map { $0.onset + $0.length }.max() ?? 0 }
    static var sampleCount: Int { Int((duration * Double(sampleRate)).rounded(.up)) }
    static var byteCount: Int { 44 + sampleCount * 2 }

    static func samples() -> [Int16] {
        let rate = Double(sampleRate)
        let radiansPerCycle = 2 * Double.pi / rate
        var mix = [Double](repeating: 0, count: sampleCount)
        // A fixed seed keeps the click, and so the whole file, byte-identical on every device.
        var noise: UInt32 = 0x1234_5678
        for stroke in strokes {
            let start = Int(stroke.onset * rate)
            var phases: [Double] = [0, 0, 0]
            var bassPhase = 0.0
            for offset in 0..<Int(stroke.length * rate) where start + offset < mix.count {
                let t = Double(offset) / rate
                let bend = 1 + (stroke.drop - 1) * exp(-t / 0.03)
                let attack = min(1, t / 0.002)
                let release = min(1, (stroke.length - t) / 0.012)
                let envelope = attack * release * exp(-stroke.decay * t)
                var value = 0.0
                for partial in 0..<3 {
                    let harmonic = Double(partial + 1)
                    phases[partial] += radiansPerCycle * stroke.pitch * harmonic * bend
                    // Higher partials fade sooner, which is what makes the ring sound struck rather than sung.
                    let fade = exp(-stroke.decay * 0.6 * (harmonic - 1) * t)
                    value += sin(phases[partial]) * pow(0.47, harmonic - 1) * fade
                }
                if let bass = stroke.bass {
                    let glide = 1 + 0.45 * exp(-t / 0.05)
                    bassPhase += radiansPerCycle * bass * glide
                    value += sin(bassPhase) * 0.8 * exp(-5 * t)
                }
                noise = noise &* 1_664_525 &+ 1_013_904_223
                let white = Double(noise >> 8) / 16_777_216 * 2 - 1
                let click = white * 0.3 * exp(-t / 0.004)
                mix[start + offset] += (value * envelope + click) * stroke.level
            }
        }
        let peak = mix.reduce(0) { max($0, abs($1)) }
        let gain = peak > 0 ? 0.8 * Double(Int16.max) / peak : 0
        return mix.map { Int16(clamping: Int(($0 * gain).rounded())) }
    }

    static func wavData() -> Data {
        let pcm = samples()
        let payload = pcm.count * 2
        var data = Data(capacity: 44 + payload)
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); uint32(UInt32(36 + payload)); text("WAVE")
        text("fmt "); uint32(16); uint16(1); uint16(1)
        uint32(UInt32(sampleRate)); uint32(UInt32(sampleRate * 2)); uint16(2); uint16(16)
        text("data"); uint32(UInt32(payload))
        pcm.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Written once under Caches. iOS may purge it, so a missing or differently sized file is written again.
    static func preparedFileURL() -> URL? {
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("GanaBajana/Delights", isDirectory: true)
        let url = directory.appendingPathComponent(fileName)
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue == byteCount {
            return url
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try wavData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// System sounds obey the silent switch, mix with whatever is playing and never touch the app's audio session.
@MainActor
final class TablaFlourishPlayer {
    private var soundID: SystemSoundID?
    private var isPreparing = false

    func play() {
        if let soundID {
            AudioServicesPlaySystemSound(soundID)
            return
        }
        guard !isPreparing else { return }
        isPreparing = true
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) { TablaFlourish.preparedFileURL() }.value
            guard let self else { return }
            self.isPreparing = false
            guard let url else { return }
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == 0 else { return }
            self.soundID = id
            AudioServicesPlaySystemSound(id)
        }
    }
}
