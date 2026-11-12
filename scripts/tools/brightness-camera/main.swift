// Records how bright the built-in camera's picture is, frame by frame, as
// numbers only (no image is ever kept). The screen lights the user's face and
// the room, so the picture brightens and darkens with the display.
//   BrightnessCamera --out file.tsv --seconds N [--lock-after S] [--parent PID]
// With --parent it stops as soon as that process is gone (a check that was
// interrupted or crashed), so the camera is never left on. It also stops on
// SIGINT and SIGTERM, and when the file <out>.stop appears.
// Writes: t (Unix time), meanLuma (0-255, whole frame), centreLuma,
// clipped (fraction of pixels at 250+), locked (1 once exposure is locked).
import AVFoundation
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
var out = "camera.tsv", seconds = 30.0, lockAfter = 2.5
var parent: pid_t = 0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--out": out = args.next() ?? out
    case "--seconds": seconds = Double(args.next() ?? "") ?? seconds
    case "--lock-after": lockAfter = Double(args.next() ?? "") ?? lockAfter
    case "--parent": parent = pid_t(args.next() ?? "") ?? 0
    default: break
    }
}

FileManager.default.createFile(atPath: out, contents: nil)
let handle = FileHandle(forWritingAtPath: out)!
func write(_ s: String) { handle.write(Data(s.utf8)) }
func log(_ s: String) { write("# \(s)\n") }
write("t\tmeanLuma\tcentreLuma\tclipped\tlocked\n")

final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var locked = false
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0, csum = 0, cn = 0, clipped = 0
        for y in Swift.stride(from: 0, to: h, by: 4) {
            let row = p + y * stride
            let inY = y > h / 4 && y < 3 * h / 4
            for x in Swift.stride(from: 0, to: w, by: 4) {
                let v = Int(row[x]); sum += v; n += 1
                if v >= 250 { clipped += 1 }
                if inY && x > w / 4 && x < 3 * w / 4 { csum += v; cn += 1 }
            }
        }
        let t = Date().timeIntervalSince1970
        write(String(format: "%.3f\t%.3f\t%.3f\t%.4f\t%d\n", t, Double(sum) / Double(n),
                     Double(csum) / Double(max(cn, 1)), Double(clipped) / Double(n), locked ? 1 : 0))
    }
}

let status = AVCaptureDevice.authorizationStatus(for: .video)
if status == .notDetermined {
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
    sem.wait()
}
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    log("error: camera permission denied"); exit(3)
}
let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else { log("error: no camera"); exit(4) }
log("camera: \(device.localizedName)")
log("exposure locked supported: \(device.isExposureModeSupported(.locked)), custom: \(device.isExposureModeSupported(.custom))")
log("white balance locked supported: \(device.isWhiteBalanceModeSupported(.locked))")

let session = AVCaptureSession()
session.sessionPreset = .vga640x480
guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { log("error: no input"); exit(5) }
session.addInput(input)
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
output.alwaysDiscardsLateVideoFrames = true
let recorder = Recorder()
let queue = DispatchQueue(label: "camera")
output.setSampleBufferDelegate(recorder, queue: queue)
session.addOutput(output)
session.startRunning()
log("started \(Date().timeIntervalSince1970)")

DispatchQueue.main.asyncAfter(deadline: .now() + lockAfter) {
    do {
        try device.lockForConfiguration()
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        device.unlockForConfiguration()
        queue.async { recorder.locked = device.exposureMode == .locked }
        log("exposure mode now \(device.exposureMode.rawValue) at \(Date().timeIntervalSince1970)")
    } catch { log("lock failed: \(error)") }
}
func stop(_ why: String) {
    session.stopRunning()
    log("stopped: \(why)")
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stop("time") }
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { stop("signal \(sig)") }
    source.resume()
    signalSources.append(source)
}
// The check asks it to stop by creating "<out>.stop".
let stopFile = out + ".stop"
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: stopFile) { stop("asked to") }
    if parent > 0 && kill(parent, 0) != 0 && errno == ESRCH { stop("the check that started it is gone") }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
