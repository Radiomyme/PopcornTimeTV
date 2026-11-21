import Foundation
import CoreGraphics
import CoreImage

/// A QR code as a crisp bitmap, made by CoreImage's own generator (no
/// dependency): each module of the code is `scale` × `scale` pixels, with
/// no smoothing, black on white with the quiet zone the generator leaves,
/// so a phone reads it on a dark screen when it sits on a light plate.
///
/// UI-free: the Apple TV's key sheet draws it (TMDB's API settings page,
/// never the key itself), the unit tests read it back.
public enum QRCodeImage {

    /// The code of `text` (UTF-8, medium error correction), nil when
    /// CoreImage cannot make one (text too long for a QR code).
    public static func make(_ text: String, scale: Int = 12) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        // One pixel per module out of the generator: whole multiples keep
        // the edges sharp (a fractional scale would blur them).
        let scaled = code.transformed(by: CGAffineTransform(scaleX: CGFloat(max(1, scale)), y: CGFloat(max(1, scale))))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}
