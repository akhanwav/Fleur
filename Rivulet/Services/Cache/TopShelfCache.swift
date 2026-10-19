// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfCache.swift
//  Rivulet
//
//  Manages shared cache for Top Shelf extension via App Groups
//

import Foundation

/// Manages read/write access to Top Shelf data in the shared App Group container
/// Used by both the main app (write) and TV Services Extension (read)
final class TopShelfCache: Sendable {
    static let shared = TopShelfCache()

    private let appGroupIdentifier = "group.com.akhanwav.fleur"
    private let cacheFileName = "top_shelf_items.json"

    private init() {}

    // MARK: - Container Access

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private var cacheFileURL: URL? {
        containerURL?.appendingPathComponent(cacheFileName)
    }

    // MARK: - UserDefaults Suite (more reliable than file access)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let userDefaultsKey = "topShelfItems"

    // MARK: - Write (Main App)

    /// Write Top Shelf items to the shared container
    /// Called by PlexDataStore when Continue Watching data is refreshed
    func writeItems(_ items: [TopShelfItem]) {

        guard let defaults = sharedDefaults else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            defaults.set(data, forKey: userDefaultsKey)
            defaults.synchronize()

            // Debug: print first item
        } catch {
        }
    }

    // MARK: - Read (Extension)

    /// Read Top Shelf items from the shared container
    /// Called by TV Services Extension to display items
    func readItems() -> [TopShelfItem] {
        guard let defaults = sharedDefaults else {
            return []
        }

        guard let data = defaults.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([TopShelfItem].self, from: data)
            return items
        } catch {
            return []
        }
    }

    // MARK: - Clear

    /// Remove all cached Top Shelf items
    func clear() {
        sharedDefaults?.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Composite image files (AppGroup/Library/Caches/TopShelf/*.jpg)

    // The container ROOT is not writable on tvOS — only `Library/Caches` under it
    // is. Creating the composites dir at the root silently failed (the mkdir error
    // was swallowed by `try?`), so every `writeComposite` then failed ENOENT and
    // Top Shelf never had a single composite to show. Keep this path in sync with
    // the extension's copy of this file, which builds the same URL independently.
    private var compositeDirName: String { "TopShelf" }

    /// The TopShelf composites directory, created if needed. nil if no container.
    func compositeDirectoryURL() -> URL? {
        guard let base = containerURL else { return nil }
        let dir = base
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(compositeDirName, isDirectory: true)
        do {
            // `withIntermediateDirectories: true` is a no-op when it already
            // exists, so the fileExists pre-check bought nothing. Do NOT swallow
            // the error here: a silent mkdir failure is what hid this bug.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("TopShelfCache: failed to create composites dir at \(dir.path): \(error)")
            return nil
        }
        return dir
    }

    func compositeFileURL(fileName: String) -> URL? {
        compositeDirectoryURL()?.appendingPathComponent(fileName)
    }

    @discardableResult
    func writeComposite(_ data: Data, fileName: String) -> Bool {
        guard let url = compositeFileURL(fileName: fileName) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { print("TopShelfCache: failed to write composite \(fileName): \(error)"); return false }
    }

    /// Delete any *.jpg in the composites dir whose name is not in `fileNames`.
    func pruneComposites(keeping fileNames: Set<String>) {
        guard let dir = compositeDirectoryURL(),
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.pathExtension.lowercased() == "jpg" {
            if !fileNames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
