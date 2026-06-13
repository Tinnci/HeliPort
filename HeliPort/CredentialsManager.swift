//
//  CredentialsManager.swift
//  HeliPort
//
//  Created by Igor Kulman on 22/06/2020.
//  Copyright © 2020 OpenIntelWireless. All rights reserved.
//

/*
 * This program and the accompanying materials are licensed and made available
 * under the terms and conditions of the The 3-Clause BSD License
 * which accompanies this distribution. The full text of the license may be found at
 * https://opensource.org/licenses/BSD-3-Clause
 */

import Foundation
@preconcurrency import KeychainAccess

actor CredentialsManager {
    static let instance: CredentialsManager = CredentialsManager()

    private let keychain: Keychain
    private let ssidCache: NSCache = NSCache<NSString, NSSet>()
    private let ssidCacheKey = NSString("savedSSIDs")

    private init() {
        keychain = Keychain(service: Bundle.main.bundleIdentifier!)
    }

    func save(_ network: NetworkInfo) {
        guard let networkAuthJson = encodedJSONString(network.auth) else {
            return
        }
        var storageNetwork = network
        storageNetwork.auth = NetworkAuth()
        let entity = NetworkInfoStorageEntity(storageNetwork)
        guard let entityJson = encodedJSONString(entity) else {
            return
        }

        ssidCache.removeObject(forKey: ssidCacheKey)

        Log.debug("Saving password for network \(network.ssid)")
        try? keychain.comment(entityJson).set(networkAuthJson, key: network.keychainKey)
    }

    func get(_ network: NetworkInfo) -> NetworkAuth? {
        guard let password = keychain[string: network.keychainKey],
            let jsonData = password.data(using: .utf8) else {
            Log.debug("No stored password for network \(network.ssid)")
            return nil
        }

        Log.debug("Loading password for network \(network.ssid)")
        return try? JSONDecoder().decode(NetworkAuth.self, from: jsonData)
    }

    func remove(_ network: NetworkInfo) {
        Log.debug("Removing \(network.ssid) from keychain")
        try? keychain.remove(network.keychainKey)
    }

    func getStorageFromSsid(_ ssid: String) -> NetworkInfoStorageEntity? {
        guard let attributes = try? keychain.get(ssid, handler: {$0}),
            let json = attributes.comment,
            let jsonData = json.data(using: .utf8) else {
                return nil
        }

        return try? JSONDecoder().decode(NetworkInfoStorageEntity.self, from: jsonData)
    }

    func getAuthFromSsid(_ ssid: String) -> NetworkAuth? {
        guard let attributes = try? keychain.get(ssid, handler: {$0}),
            let jsonData = attributes.data
            else {
                return nil
        }

        return try? JSONDecoder().decode(NetworkAuth.self, from: jsonData)
    }

    func setAutoJoin(_ ssid: String, _ autoJoin: Bool) {
        guard var entity = getStorageFromSsid(ssid),
            let auth = getAuthFromSsid(ssid) else {
                return
        }

        entity.autoJoin = autoJoin

        guard let entityJson = encodedJSONString(entity),
              let authJson = encodedJSONString(auth) else {
            return
        }

        try? keychain.comment(entityJson).set(authJson, key: ssid)
    }

    func setPriority(_ ssid: String, _ priority: Int) {
        guard var entity = getStorageFromSsid(ssid),
            let auth = getAuthFromSsid(ssid) else {
                return
        }

        entity.order = priority

        guard let entityJson = encodedJSONString(entity),
              let authJson = encodedJSONString(auth) else {
            return
        }

        try? keychain.comment(entityJson).set(authJson, key: ssid)
    }

    func getSavedNetworks() -> [NetworkInfo] {
        return (keychain.allKeys().compactMap { ssid in
            return getStorageFromSsid(ssid)
        } as [NetworkInfoStorageEntity]).filter { entity in
            entity.autoJoin && entity.version == NetworkInfoStorageEntity.CURRENT_VERSION
        }.sorted {
            $0.order < $1.order
        }.map { entity in
            entity.network
        }
    }

    func getSavedNetworkSSIDs() -> Set<String> {
        if let cached = ssidCache.object(forKey: ssidCacheKey) as? Set<String> {
            return cached
        }
        let savedSSIDs = Set(keychain.allKeys())
        ssidCache.setObject(savedSSIDs as NSSet, forKey: ssidCacheKey)
        return savedSSIDs
    }

    func getSavedNetworksEntity() -> [NetworkInfoStorageEntity] {
        return (keychain.allKeys().compactMap { ssid in
            return getStorageFromSsid(ssid)
        } as [NetworkInfoStorageEntity]).filter { entity in
            entity.version == NetworkInfoStorageEntity.CURRENT_VERSION
        }.sorted {
            $0.order < $1.order
        }.map { entity in
            var entity = entity
            guard let auth = getAuthFromSsid(entity.network.ssid) else {
                return entity
            }
            entity.network.auth = auth
            return entity
        }
    }

    private func encodedJSONString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

fileprivate extension NetworkInfo {
    var keychainKey: String {
        return ssid
    }
}
