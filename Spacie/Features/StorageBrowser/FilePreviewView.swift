import SwiftUI
import AVFoundation
import QuickLookThumbnailing

// MARK: - FilePreviewView

/// Thumbnail preview for a single file under the right panel donut chart.
///
/// Targets the "see-what-you're-about-to-delete" workflow: single-click an
/// image or video row in `FolderListPanel`, the thumbnail materialises here
/// so the user can confirm visually before invoking Move to Trash.
///
/// Load strategy is ordered by reliability inside a sandboxed/TCC-restricted
/// environment:
///  1. `NSImage(contentsOfFile:)` for images — direct, no service round-trip.
///  2. `AVAssetImageGenerator` for video — extracts the first frame.
///  3. `QLThumbnailGenerator` as a universal fallback for anything else.
///
/// The frame is fixed-height to eliminate the layout jitter the previous
/// implementation produced as it transitioned between ProgressView and the
/// loaded thumbnail.
struct FilePreviewView: View {

    enum Kind { case image, video, other }

    let fileURL: URL
    let fileName: String
    let fileSize: UInt64
    let kind: Kind

    /// Locked vertical dimension for the thumbnail box so async loading does
    /// not cause the surrounding `FileTypePanel` to relayout each frame.
    private let imageBoxHeight: CGFloat = 220

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if loadFailed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageBoxHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteString(fileSize))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        // `.task(id:)` re-runs whenever `fileURL` changes — this is the only
        // reliable trigger because `mediaPreviewSection` rebuilds the
        // `FilePreviewView` struct on selection, but SwiftUI keeps the same
        // identity (the parent's HStack slot stays put) so `.onAppear` never
        // fires again and `@State image` would otherwise stay frozen on the
        // first file.
        .task(id: fileURL) {
            await loadAndCancellable()
        }
    }

    // MARK: - Loading

    /// Driven by `.task(id: fileURL)` — invoked on initial appear and on every
    /// `fileURL` change. Reset state then load; cancellation is automatic when
    /// `.task` is torn down.
    private func loadAndCancellable() async {
        image = nil
        loadFailed = false

        let url = fileURL
        let kind = self.kind
        let pixelSize: CGFloat = imageBoxHeight * 2 // 2x for Retina

        let loaded = await Self.generateThumbnail(for: url, kind: kind, pixelSize: pixelSize)
        if Task.isCancelled { return }
        if let loaded {
            self.image = loaded
        } else {
            self.loadFailed = true
        }
    }

    /// Tries native loaders first (cheapest), falls back to QuickLook.
    nonisolated private static func generateThumbnail(
        for url: URL,
        kind: Kind,
        pixelSize: CGFloat
    ) async -> NSImage? {
        // Native path: avoids the QuickLookThumbnailing XPC and the sandboxed
        // file-access pitfalls that produced the "Preview unavailable" placeholder.
        switch kind {
        case .image:
            if let img = NSImage(contentsOfFile: url.path) {
                return img
            }
        case .video:
            if let frame = await Self.firstVideoFrame(url: url, pixelSize: pixelSize) {
                return frame
            }
        case .other:
            break
        }

        return await Self.quickLookThumbnail(url: url, pixelSize: pixelSize)
    }

    nonisolated private static func firstVideoFrame(
        url: URL,
        pixelSize: CGFloat
    ) async -> NSImage? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        return await withCheckedContinuation { continuation in
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                if let cg = cgImage {
                    let size = CGSize(width: cg.width, height: cg.height)
                    continuation.resume(returning: NSImage(cgImage: cg, size: size))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func quickLookThumbnail(
        url: URL,
        pixelSize: CGFloat
    ) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep.nsImage
        } catch {
            #if DEBUG
            print("[FilePreviewView] QuickLook failed for \(url.path): \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Helpers

    private func byteString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
