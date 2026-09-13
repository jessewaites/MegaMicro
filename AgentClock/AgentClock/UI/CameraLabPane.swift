import SwiftUI

struct CameraLabPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Camera lab").font(.title2.bold())
                Text("Live Mac camera frames reduced to the clock's 32×8 pixels. Frames are processed locally and are neither saved nor uploaded.")
                    .foregroundStyle(.secondary)

                MatrixView(canvas: model.cameraLab.canvas, pixelSize: 18)

                HStack(spacing: 12) {
                    Button(model.cameraLab.isRunning ? "Stop" : "Start camera") {
                        model.cameraLab.isRunning ? model.stopCameraLab() : model.startCameraLab()
                    }
                    .keyboardShortcut(.defaultAction)

                    Spacer()
                    if model.cameraLab.isRunning && !model.config.clockHost.isEmpty {
                        Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Label(model.cameraLab.status, systemImage: "camera")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text("The mirrored camera image is center-cropped to the matrix's wide 4:1 shape. At 32×8 the result is intentionally lo-fi—lighting, silhouette, and motion read better than detail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 660, alignment: .leading)
        }
        .onDisappear { model.stopCameraLab() }
    }
}
