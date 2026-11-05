import AVFoundation
import SwiftUI
import UIKit

/// A UIView whose backing layer is the camera preview layer.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: layerClass guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// SwiftUI wrapper around the preview with tap / long-press / pinch gestures.
///
/// UIViewRepresentable is SwiftUI's bridge to UIKit views (like a React component that
/// manages a DOM node by hand). Gestures live in UIKit to get exact touch positions.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    /// Tap: (point in view, point in camera coordinates 0...1).
    var onTap: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onLongPress: (CGPoint, CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        camera.attachPreviewLayer(view.previewLayer)

        let coordinator = context.coordinator
        coordinator.view = view
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = 0.6
        tap.require(toFail: longPress)
        [pinch, tap, longPress].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        weak var view: PreviewView?
        private var pinchStartZoom: CGFloat = 1

        init(parent: CameraPreview) {
            self.parent = parent
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStartZoom = parent.camera.displayZoom
            case .changed:
                parent.camera.setZoom(pinchStartZoom * gesture.scale, animated: false)
            default:
                break
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            guard let devicePoint = devicePoint(for: point, in: view) else { return }
            parent.onTap(point, devicePoint)
        }

        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view else { return }
            let point = gesture.location(in: view)
            guard let devicePoint = devicePoint(for: point, in: view) else { return }
            parent.onLongPress(point, devicePoint)
        }

        /// Converts a touch to the camera's 0...1 coordinate space; `nil` outside the picture.
        private func devicePoint(for point: CGPoint, in view: PreviewView) -> CGPoint? {
            let layer = view.previewLayer
            let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
            guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return nil }
            return devicePoint
        }
    }
}
