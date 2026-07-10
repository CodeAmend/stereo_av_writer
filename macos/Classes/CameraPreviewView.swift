import AVFoundation
import Cocoa
import FlutterMacOS

/// v0.2.0 (stretto v0.79.3) — embedded live preview.
///
/// The Flutter `AppKitView` and the recorder's capture session are created
/// independently (the platform view mounts from the widget tree; the session
/// starts from an async `startPreview` call), so they rendezvous through this
/// tiny shared registry rather than a direct reference. `CameraRecorder` sets
/// `session` when it starts previewing; the preview view binds its layer to
/// whatever is current and re-binds if it changes.
final class PreviewSessionRegistry {
    static let shared = PreviewSessionRegistry()
    private init() {}

    weak var session: AVCaptureSession? {
        didSet { onChange?() }
    }
    /// Fired on the main thread when `session` changes so a live preview view rebinds.
    var onChange: (() -> Void)?

    // v0.82 .3b — mirror flag for the record surface (arch-82 D2). Applied to the
    // preview layer's connection here AND, in lockstep, to the recorder's output
    // connection (so preview == recording, true WYSIWYG). Default ON: an instrument
    // reads naturally (piano bass stays on the left); flip off for behind/overhead.
    var mirrored: Bool = true {
        didSet { onMirrorChange?() }
    }
    /// Fired on the main thread when `mirrored` changes so a live preview re-applies it.
    var onMirrorChange: (() -> Void)?
}

/// Layer-hosting NSView whose backing layer is an `AVCaptureVideoPreviewLayer`
/// bound to the registry's current session. Mirrors the proven throwaway-window
/// layer setup from the camera slice.
final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = previewLayer          // layer-hosting: set layer BEFORE wantsLayer
        wantsLayer = true
        bind()
        PreviewSessionRegistry.shared.onChange = { [weak self] in
            DispatchQueue.main.async { self?.bind() }
        }
        PreviewSessionRegistry.shared.onMirrorChange = { [weak self] in
            DispatchQueue.main.async { self?.applyMirror() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func bind() {
        previewLayer.session = PreviewSessionRegistry.shared.session
        applyMirror()
    }

    // Preview-only mirror. Off the connection's auto-adjust so our value sticks;
    // the recorded videoOutput connection is a different object and is untouched.
    private func applyMirror() {
        guard let conn = previewLayer.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = PreviewSessionRegistry.shared.mirrored
    }
}

/// Registered under the view type `stereo_av_writer/preview`; the Dart side
/// renders it with `AppKitView(viewType: 'stereo_av_writer/preview')`.
final class CameraPreviewViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        return CameraPreviewNSView(frame: .zero)
    }
}
