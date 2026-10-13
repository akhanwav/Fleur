// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleImageReader.swift
//  Rivulet
//
//  Reads the words out of image subtitle cues (PGS, VobSub, DVB) on the
//  device, so the content filter can match them like text cues.
//

import CoreGraphics
import Foundation
import Vision

/// Recognised text per image cue. Cues are read ahead of the playhead, one at
/// a time, so a line's text is usually known before it is spoken.
@MainActor
final class SubtitleImageReader {
    /// Called when a cue's text arrives, so the filter can be fed again.
    var onRead: (() -> Void)?

    private var texts: [ObjectIdentifier: (image: CGImage, text: String)] = [:]
    private var wanted: [CGImage] = []
    private var isReading = false
    private let recognize: @Sendable (CGImage) -> String
    // Vision blocks its thread; keep that off the main and cooperative threads.
    private let queue = DispatchQueue(label: "rivulet.subtitle-image-reader", qos: .utility)

    init(recognize: @escaping @Sendable (CGImage) -> String = { SubtitleImageReader.recognize($0) }) {
        self.recognize = recognize
    }

    /// The cue's text; nil until it has been read.
    func text(for image: CGImage) -> String? {
        texts[ObjectIdentifier(image)]?.text
    }

    /// The images worth reading, soonest first. Everything else is forgotten,
    /// which bounds the cache and empties it on an item or track change.
    func read(_ images: [CGImage]) {
        wanted = images
        let keep = Set(images.map { ObjectIdentifier($0) })
        texts = texts.filter { keep.contains($0.key) }
        readNext()
    }

    private func readNext() {
        guard !isReading, let image = wanted.first(where: { texts[ObjectIdentifier($0)] == nil }) else { return }
        isReading = true
        let recognize = recognize
        queue.async { [weak self] in
            let text = recognize(image)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                // A cue dropped while it was being read is not kept.
                if self.wanted.contains(where: { $0 === image }) {
                    self.texts[ObjectIdentifier(image)] = (image, text)
                    self.onRead?()
                }
                self.readNext()
            }
        }
    }

    // MARK: - Recognition

    /// The words in a subtitle bitmap, one line per row; "" when nothing can be read.
    nonisolated static func recognize(_ image: CGImage) -> String {
        guard let flat = flattened(image) else { return "" }
        // Accurate reads best; fast is the fallback where its model can't run.
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            guard (try? VNImageRequestHandler(cgImage: flat).perform([request])) != nil else { continue }
            // Vision's origin is bottom-left: the top line has the largest y.
            return (request.results ?? [])
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        return ""
    }

    /// Subtitle bitmaps are light glyphs on transparency; Vision needs a solid backing.
    nonisolated static func flattened(_ image: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard image.width > 0, image.height > 0, let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
