// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CachedAsyncImage.swift
//  Rivulet
//
//  Drop-in replacement for AsyncImage with persistent disk caching
//

import SwiftUI

/// Image loading phase for CachedAsyncImage (matches AsyncImagePhase)
enum CachedAsyncImagePhase {
    case empty
    case success(Image)
    case failure(Error)

    /// The loaded image, if available
    var image: Image? {
        if case .success(let image) = self {
            return image
        }
        return nil
    }

    /// The error, if loading failed
    var error: Error? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

/// A view that asynchronously loads and displays an image with persistent disk caching.
/// Drop-in replacement for SwiftUI's AsyncImage with 2-week TTL and 5GB disk cache.
/// Uses synchronous memory cache check for instant display without loading flash.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (CachedAsyncImagePhase) -> Content

    @State private var phase: CachedAsyncImagePhase = .empty
    @State private var loadTask: Task<Void, Never>?

    init(url: URL?, @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
            .onDisappear {
                loadTask?.cancel()
            }
    }

    private func loadImage() async {
        // Cancel any existing load
        loadTask?.cancel()

        guard let url else {
            phase = .failure(URLError(.badURL))
            return
        }

        // Quick memory cache check first (nearly instant)
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            phase = .success(Image(uiImage: cached))
            // Still trigger background refresh for stale-while-revalidate
            Task.detached(priority: .low) {
                _ = await ImageCacheManager.shared.image(for: url)
            }
            return
        }

        // Use detached task to avoid blocking the view's task
        loadTask = Task {
            // Load on background thread
            let image = await Task.detached(priority: .userInitiated) {
                await ImageCacheManager.shared.image(for: url)
            }.value

            // Update UI only if not cancelled
            if !Task.isCancelled {
                if let uiImage = image {
                    phase = .success(Image(uiImage: uiImage))
                } else {
                    phase = .failure(URLError(.cannotLoadFromNetwork))
                }
            }
        }
        // Don't await - let it complete in background without blocking
    }
}

// MARK: - Convenience Initializers

extension CachedAsyncImage {
    /// Creates a cached async image with default placeholder and error views
    init(url: URL?) where Content == _ConditionalContent<_ConditionalContent<ProgressView<EmptyView, EmptyView>, Image>, Color> {
        self.init(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView()
            case .success(let image):
                image.resizable()
            case .failure:
                Color(white: 0.15)
            }
        }
    }

    /// Creates a cached async image with custom content and placeholder
    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if let image = phase.image {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Phase-based usage (like AsyncImage)
        CachedAsyncImage(url: URL(string: "https://example.com/image.jpg")) { phase in
            switch phase {
            case .empty:
                ProgressView()
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 200, height: 300)
        .clipped()

        // Simplified usage
        CachedAsyncImage(url: URL(string: "https://example.com/image2.jpg")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay { ProgressView() }
        }
        .frame(width: 200, height: 300)
        .clipped()
    }
}
