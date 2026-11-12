// Shared by the camera checks (light-check, gamma-check): reading the camera
// meter's numbers, and making sure the room is dark enough to trust them.
import Foundation

/// The camera meter's frames so far: (wall-clock time, mean luma).
func cameraFrames(_ path: String) -> [(Double, Double)] {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t")
        guard parts.count >= 2, let t = Double(parts[0]), let v = Double(parts[1]) else { return nil }
        return (t, v)
    }
}

func cameraMean(_ frames: [(Double, Double)], _ from: Double, _ to: Double) -> Double {
    let s = frames.filter { $0.0 >= from && $0.0 < to }.map(\.1)
    return s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count)
}

/// How much of what the camera sees comes from the screen. The white patch
/// and a black one alternate; in a dark room the camera reads far less with
/// the patch black, in a lit room almost the same.
struct RoomCheck {
    var white: Double
    var black: Double
    /// Below this, room light drowns the screen and the camera's auto exposure
    /// evens out the differences being measured.
    static let minimumShare = 0.2
    var screenShare: Double { white > 0 ? (white - black) / white : 0 }
    var isDark: Bool { screenShare.isFinite && screenShare >= Self.minimumShare }
    var summary: String {
        String(format: "camera %.1f with the white patch, %.1f with it black: the screen gives %.0f%% of the light the camera sees (needs %.0f%%)",
               white, black, screenShare * 100, Self.minimumShare * 100)
    }
    static let advice = """
    The room is too bright for the camera to see the screen. Turn off the lights, \
    close the curtains, and make sure no other screen or lamp is in view, then run this again.
    """
}

/// Three cycles of white and black patch, 1.5 s each, read from the camera file.
func checkRoom(cameraFile: String, setPatch: (Double) -> Void, pump: (Double) -> Void,
               now: () -> Double) -> RoomCheck {
    var whites: [(Double, Double)] = [], blacks: [(Double, Double)] = []
    for _ in 0..<3 {
        setPatch(1); let w = now(); pump(1.5); whites.append((w + 0.6, w + 1.45))
        setPatch(0); let b = now(); pump(1.5); blacks.append((b + 0.6, b + 1.45))
    }
    setPatch(1)
    pump(1)
    let frames = cameraFrames(cameraFile)
    func average(_ windows: [(Double, Double)]) -> Double {
        let values = windows.map { cameraMean(frames, $0.0, $0.1) }.filter { !$0.isNaN }
        return values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }
    return RoomCheck(white: average(whites), black: average(blacks))
}
