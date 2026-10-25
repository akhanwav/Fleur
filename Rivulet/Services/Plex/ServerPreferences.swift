// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerPreferences.swift
//  Rivulet
//
//  The user's choices about their Plex servers, for everything that looks
//  across servers (Ways to Watch, On Your Servers, the filmography and the
//  copy a detail page opens on): which servers are on, in what order, and
//  which server each title was last watched from. Home and Library stay on
//  the selected (main) server; nothing here changes that.
//
//  Resume points are not here: Plex keeps one per server, and each copy's
//  is read from its own server.
//

import Foundation

nonisolated enum ServerPreferences {
    struct KnownServer: Codable, Hashable, Sendable {
        let machineId: String
        let name: String
    }

    private static let orderKey = "plexServerOrder"
    private static let disabledKey = "plexServersDisabled"
    private static let knownKey = "plexKnownServers"
    private static let lastWatchedKey = "plexLastWatchedServer"
    /// Titles remembered for "last watched on"; the oldest drop first.
    private static let lastWatchedLimit = 400

    private static var defaults: UserDefaults { .standard }

    // MARK: Known servers

    /// Every server this account has seen, main first then the rest in the
    /// user's order. Fed by `OtherServersAvailabilityChecker` each time it
    /// resolves the server list, so Settings can list them without a fetch.
    static var knownServers: [KnownServer] {
        guard let data = defaults.data(forKey: knownKey),
              let servers = try? JSONDecoder().decode([KnownServer].self, from: data) else { return [] }
        return sorted(servers, by: \.machineId)
    }

    static func remember(_ servers: [KnownServer]) {
        var merged = Dictionary(knownServers.map { ($0.machineId, $0) }, uniquingKeysWith: { a, _ in a })
        for server in servers { merged[server.machineId] = server }
        guard let data = try? JSONEncoder().encode(Array(merged.values)) else { return }
        defaults.set(data, forKey: knownKey)
    }

    // MARK: On / off

    /// The main server is always on: it is the one Home and Library show.
    static func isEnabled(_ machineId: String) -> Bool {
        machineId == mainMachineId || !disabled.contains(machineId)
    }

    static func setEnabled(_ machineId: String, _ enabled: Bool) {
        var set = disabled
        if enabled { set.remove(machineId) } else { set.insert(machineId) }
        defaults.set(Array(set), forKey: disabledKey)
    }

    private static var disabled: Set<String> {
        Set(defaults.stringArray(forKey: disabledKey) ?? [])
    }

    // MARK: Order

    /// `items` in the user's server order. Servers never ordered keep the
    /// main server first, then their name order.
    static func sorted<T>(_ items: [T], by machineId: (T) -> String) -> [T] {
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let main = mainMachineId
        func rank(_ id: String) -> Int {
            if let index = order.firstIndex(of: id) { return index }
            return order.count + (id == main ? 0 : 1)
        }
        return items.enumerated().sorted { a, b in
            let ra = rank(machineId(a.element)), rb = rank(machineId(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Move one server a slot up or down among `ids` (the list as shown),
    /// then store that whole list as the order.
    static func move(_ machineId: String, up: Bool, among ids: [String]) {
        var ids = sorted(ids, by: { $0 })
        guard let index = ids.firstIndex(of: machineId) else { return }
        let target = up ? index - 1 : index + 1
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        defaults.set(ids, forKey: orderKey)
    }

    // MARK: Last watched

    /// The server a title (by Plex guid) was last played from.
    static func lastWatchedServer(forGuid guid: String) -> String? {
        (defaults.dictionary(forKey: lastWatchedKey) as? [String: String])?[guid]
    }

    /// Record a play: the title's own guid, and its show's for an episode,
    /// so the show page opens on the same server too.
    static func recordWatched(guids: [String?], machineId: String) {
        var map = (defaults.dictionary(forKey: lastWatchedKey) as? [String: String]) ?? [:]
        var order = defaults.stringArray(forKey: lastWatchedKey + ".order") ?? []
        for guid in guids.compactMap({ $0 }) where guid.hasPrefix("plex://") {
            map[guid] = machineId
            order.removeAll { $0 == guid }
            order.append(guid)
        }
        while order.count > lastWatchedLimit { map[order.removeFirst()] = nil }
        defaults.set(map, forKey: lastWatchedKey)
        defaults.set(order, forKey: lastWatchedKey + ".order")
    }

    // MARK: Main server

    /// The selected server's machine id, read from the saved selection.
    static var mainMachineId: String? {
        defaults.string(forKey: mainMachineIdKey)
    }

    static func setMainMachineId(_ id: String?) {
        defaults.set(id, forKey: mainMachineIdKey)
    }

    private static let mainMachineIdKey = "plexMainServerMachineId"
}
