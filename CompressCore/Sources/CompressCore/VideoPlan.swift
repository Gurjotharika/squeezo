import CoreGraphics
import Foundation

/// What we know about the source video track.
struct VideoSourceInfo {
    var size: CGSize  // unrotated pixel size
    var frameRate: Double
    var isHDR: Bool
}

/// The encoder settings chosen for a video, as pure arithmetic so it can be tested without any media.
struct VideoPlan: Equatable {
    var width: Int
    var height: Int
    var frameRate: Double
    var quality: Double
    var codec: VideoCodec
    var isHDR: Bool
    /// True when frames must be dropped to reach `frameRate`.
    var dropsFrames: Bool

    static func make(source: VideoSourceInfo, preset: Preset) -> VideoPlan {
        let sourceWidth = max(source.size.width, 2)
        let sourceHeight = max(source.size.height, 2)

        // Scale down only, keeping the aspect ratio.
        var scale = 1.0
        if let maxSide = preset.maxDimension, maxSide > 0 {
            scale = min(1, Double(maxSide) / max(sourceWidth, sourceHeight))
        }
        let width = even(sourceWidth * scale)
        let height = even(sourceHeight * scale)

        let sourceFPS = source.frameRate > 0 ? source.frameRate : 30
        var fps = sourceFPS
        var drops = false
        if let cap = preset.maxFrameRate, Double(cap) < sourceFPS * 0.95 {
            fps = Double(cap)
            drops = true
        }

        // HDR needs 10-bit HEVC; H.264 can't carry it.
        let codec: VideoCodec = source.isHDR ? .hevc : preset.videoCodec

        return VideoPlan(
            width: width, height: height, frameRate: fps, quality: preset.level.videoQuality,
            codec: codec, isHDR: source.isHDR, dropsFrames: drops)
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}

/// How the audio track is carried into the output.
enum AudioPlan: Equatable {
    case passthrough
    case reencode(bitRate: Int, channels: Int)

    /// - Parameters:
    ///   - formatID: Core Audio format ID of the source track (e.g. `kAudioFormatMPEG4AAC`).
    static func make(formatID: UInt32, bitRate: Double, channels: Int, level: QualityLevel, isMOV: Bool) -> AudioPlan {
        let aac: UInt32 = 0x6161_6320  // 'aac '
        let ac3: UInt32 = 0x6163_2D33  // 'ac-3'
        let eac3: UInt32 = 0x6563_2D33  // 'ec-3'
        let alac: UInt32 = 0x616C_6163  // 'alac'
        let compatible = [aac, ac3, eac3].contains(formatID) || (isMOV && formatID == alac)

        // Only AAC is worth shrinking; other compatible formats are copied as they are.
        if formatID == aac {
            let limit: Double? = switch level {
            case .highest, .high: nil
            case .medium: 160_000
            case .low: 120_000
            }
            if let limit, bitRate > limit {
                return .reencode(bitRate: level == .low ? 96_000 : 128_000, channels: min(max(channels, 1), 2))
            }
            return .passthrough
        }
        if compatible { return .passthrough }

        let target = switch level {
        case .highest, .high: 192_000
        case .medium: 128_000
        case .low: 96_000
        }
        let ch = min(max(channels, 1), 2)
        return .reencode(bitRate: ch == 1 ? target / 2 : target, channels: ch)
    }
}
