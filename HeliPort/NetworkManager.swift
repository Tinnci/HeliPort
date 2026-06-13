//
//  NetworkManager.swift
//  HeliPort
//
//  Created by 梁怀宇 on 2020/3/23.
//  Copyright © 2020 OpenIntelWireless. All rights reserved.
//

/*
 * This program and the accompanying materials are licensed and made available
 * under the terms and conditions of the The 3-Clause BSD License
 * which accompanies this distribution. The full text of the license may be found at
 * https://opensource.org/licenses/BSD-3-Clause
 */

import Foundation
import SystemConfiguration

final class NetworkManager {
    static let supportedSecurityMode = [
        ITL80211_SECURITY_NONE,
        ITL80211_SECURITY_WEP,
        ITL80211_SECURITY_WPA_PERSONAL,
        ITL80211_SECURITY_WPA_PERSONAL_MIXED,
        ITL80211_SECURITY_WPA2_PERSONAL,
        ITL80211_SECURITY_PERSONAL
    ]

    private actor AssociationFailureStore {
        private var summary: String?

        func get() -> String? {
            return summary
        }

        func set(_ summary: String?) {
            self.summary = summary
        }

        func clear() {
            summary = nil
        }
    }

    private static let associationFailureStore = AssociationFailureStore()

    @MainActor
    static func connect(networkInfo: NetworkInfo, saveNetwork: Bool = false,
                        _ callback: (@MainActor @Sendable (_ result: Bool) -> Void)? = nil) {
        Task { @MainActor in
            let result = await connect(networkInfo: networkInfo, saveNetwork: saveNetwork)
            callback?(result)
        }
    }

    @MainActor
    @discardableResult
    static func connect(networkInfo: NetworkInfo, saveNetwork: Bool = false) async -> Bool {
        guard supportedSecurityMode.contains(networkInfo.auth.security) else {
            let alert = Alert(text: NSLocalizedString("Network security not supported: ")
                              + networkInfo.auth.security.description)
            alert.show()
            return false
        }

        var network = networkInfo
        var shouldSave = saveNetwork

        // Getting keychain access blocks UI Thread and makes everything freeze unless made async
        if let savedNetworkAuth = await CredentialsManager.instance.get(network) {
            network.auth = savedNetworkAuth
            shouldSave = false
            Log.debug("Connecting to network \(network.ssid) with saved password")
            await CredentialsManager.instance.setAutoJoin(network.ssid, true)
        } else if network.auth.security != ITL80211_SECURITY_NONE,
                  network.auth.password.isEmpty {
            guard let authInfo = await requestAuthInfo(for: network) else {
                return false
            }
            network.auth = authInfo.auth
            shouldSave = authInfo.savePassword
        }

        StatusBarIcon.shared().connecting()
        let ssid = network.ssid
        let password = network.auth.password
        let result = await Task.detached(priority: .background) {
            return connect_network(ssid, password)
        }.value

        if result {
            await clearAssociationFailure()
            if shouldSave {
                await CredentialsManager.instance.save(network)
            }
        } else {
            let failure = await refreshAssociationFailure()
            StatusBarIcon.shared().warning()
            Log.error("Failed to connect to: \(network.ssid)" +
                      (failure.map { " (\($0))" } ?? ""))
        }

        return result
    }

    @MainActor
    private static func requestAuthInfo(
        for networkInfo: NetworkInfo
    ) async -> (auth: NetworkAuth, savePassword: Bool)? {
        return await withCheckedContinuation { continuation in
            WiFiConfigWindow(windowState: .connectWiFi,
                             networkInfo: networkInfo,
                             getAuthInfoCallback: { auth, savePassword in
                                 continuation.resume(returning: (auth, savePassword))
                             }).show()
        }
    }

    static func lastAssociationFailure() async -> String? {
        return await associationFailureStore.get()
    }

    @discardableResult
    static func refreshAssociationFailure() async -> String? {
        var status = ioctl_assoc_status()
        guard get_assoc_status(&status) else { return await lastAssociationFailure() }

        let summary = associationFailureDescription(status)
        await associationFailureStore.set(summary)
        return summary
    }

    static func clearAssociationFailure() async {
        await associationFailureStore.clear()
    }

    @MainActor
    static func scanNetwork(sortBy areInIncreasingOrder: @escaping @Sendable (NetworkInfo, NetworkInfo) -> Bool
                                = { $0.ssid < $1.ssid },
                            callback: @escaping @MainActor @Sendable (_ sortedNetworkInfoList: [NetworkInfo]) -> Void) {
        Task { @MainActor in
            let result = await scanNetwork()
            callback(result.sorted(by: areInIncreasingOrder))
        }
    }

    @MainActor
    static func scanNetwork(sortBy areInIncreasingOrder: @escaping @Sendable (NetworkInfo, NetworkInfo) -> Bool
                                = { $0.ssid < $1.ssid },
                            callback: @escaping @MainActor @Sendable (_ knownNetworks: [NetworkInfo],
                                                                      _ otherNetworks: [NetworkInfo]) -> Void) {
        Task { @MainActor in
            let savedSSIDs = await CredentialsManager.instance.getSavedNetworkSSIDs()
            let result = await scanNetwork()
            let known = result.filter { savedSSIDs.contains($0.ssid) }
            let other = result.subtracting(known)

            callback(known.sorted(by: areInIncreasingOrder),
                     other.sorted(by: areInIncreasingOrder))
        }
    }

    private static func scanNetwork() async -> Set<NetworkInfo> {
        return await Task.detached(priority: .background) {
            var list = network_info_list_t()
            get_network_list(&list)

            var result = Set<NetworkInfo>()
            let networks = Mirror(reflecting: list.networks).children.map({ $0.value }).prefix(Int(list.count))

            for element in networks {
                guard let network = element as? ioctl_network_info else {
                    continue
                }
                let ssid = String(ssid: network.ssid)
                guard !ssid.isEmpty else {
                    continue
                }

                var networkInfo = NetworkInfo(
                    ssid: ssid,
                    rssi: Int(network.rssi)
                )
                networkInfo.auth.security = getSecurityType(network)
                result.insert(networkInfo)
            }

            return result
        }.value
    }

    static func scanSavedNetworks() {
        Task.detached(priority: .background) {
            let savedNetworks: [NetworkInfo] = await CredentialsManager.instance.getSavedNetworks()
            guard savedNetworks.count > 0 else {
                Log.debug("No network saved for auto join")
                return
            }
            while !Task.isCancelled {
                let networkList = await scanNetwork()
                let targetNetworks = savedNetworks.filter { networkList.contains($0) }
                if targetNetworks.count > 0 {
                    Log.debug("Auto join scan stopped")
                    await connectSavedNetworks(networks: targetNetworks)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private static func connectSavedNetworks(networks: [NetworkInfo]) async {
        for network in networks {
            let connected = await connect(networkInfo: network)
            if connected {
                return
            }
        }
    }

    // Credit: vadian
    // https://stackoverflow.com/a/31838376/13164334
    static func getMACAddressFromBSD(bsd: String) -> String? {
        let MAC_ADDRESS_LENGTH = 6
        let separator = ":"

        var length: size_t = 0
        var buffer: [CChar]

        let bsdIndex = Int32(if_nametoindex(bsd))
        if bsdIndex == 0 {
            Log.error("Could not find index for bsd name \(bsd)")
            return nil
        }
        let bsdData = Data(bsd.utf8)
        var managementInfoBase = [CTL_NET,
                                  AF_ROUTE,
                                  0,
                                  AF_LINK,
                                  NET_RT_IFLIST,
                                  bsdIndex]

        if sysctl(&managementInfoBase, 6, nil, &length, nil, 0) < 0 {
            Log.error("Could not determine length of info data structure")
            return nil
        }

        buffer = [CChar](unsafeUninitializedCapacity: length, initializingWith: {buffer, initializedCount in
            for idx in 0..<length { buffer[idx] = 0 }
            initializedCount = length
        })

        if sysctl(&managementInfoBase, 6, &buffer, &length, nil, 0) < 0 {
            Log.error("Could not read info data structure")
            return nil
        }

        let infoData = Data(bytes: buffer, count: length)
        let indexAfterMsghdr = MemoryLayout<if_msghdr>.stride + 1
        let rangeOfToken = infoData[indexAfterMsghdr...].range(of: bsdData)!
        let lower = rangeOfToken.upperBound
        let upper = lower + MAC_ADDRESS_LENGTH
        let macAddressData = infoData[lower..<upper]
        let addressBytes = macAddressData.map { String(format: "%02x", $0) }
        return addressBytes.joined(separator: separator)
    }

    static func isReachable() -> Bool {
        guard let reachability = SCNetworkReachabilityCreateWithName(nil, "captive.apple.com") else {
            return false
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)

        var flags = SCNetworkReachabilityFlags()
        SCNetworkReachabilityGetFlags(reachability, &flags)

        let isReachable: Bool = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let canConnectAutomatically = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
        let canConnectWithoutUserInteraction = canConnectAutomatically && !flags.contains(.interventionRequired)
        return isReachable && (!needsConnection || canConnectWithoutUserInteraction)
    }

    static func getRouterAddress(bsd: String) -> String? {
        return getRouterAddressFromSysctl(bsd) ?? getRouterAddressFromNetstat(bsd)
    }

    // from https://stackoverflow.com/questions/30748480/swift-get-devices-wifi-ip-address/30754194#30754194
    static func getLocalAddress(bsd: String) -> String? {
        // Get list of all interfaces on the local machine:
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        var ipV4: String?
        var ipV6: String?

        // For each interface ...
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee

            // Check for IPv4 or IPv6 interface:
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) else {
                continue
            }

            // Check interface name:
            let name = String(cString: interface.ifa_name)
            guard name == bsd else {
                continue
            }

            // Convert interface address to a human readable string:
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, socklen_t(0), NI_NUMERICHOST)

            if addrFamily == UInt8(AF_INET) {
                ipV4 = string(fromNullTerminatedCChars: hostname)
            } else if addrFamily == UInt8(AF_INET6) {
                ipV6 = string(fromNullTerminatedCChars: hostname)
            }
        }

        freeifaddrs(ifaddr)

        // ipV4 has priority
        return ipV4 ?? ipV6
    }

    static func getSecurityType(_ info: ioctl_network_info) -> itl80211_security {
        return getSecurityType(rsnprotos: info.supported_rsnprotos, rsnakms: info.rsn_akms)
    }

    static func getSecurityType(_ status: ioctl_assoc_status) -> itl80211_security {
        return getSecurityType(rsnprotos: status.selected_rsnprotos, rsnakms: status.selected_rsnakms)
    }

    private static func getSecurityType(rsnprotos: UInt32, rsnakms: UInt32) -> itl80211_security {
        if rsnprotos & ITL80211_PROTO_RSN.rawValue != 0 {
            // WPA2
            if rsnakms & ITL80211_AKM_8021X.rawValue != 0 {
                if rsnprotos & ITL80211_PROTO_WPA.rawValue != 0 {
                    return ITL80211_SECURITY_WPA_ENTERPRISE_MIXED
                }
                return ITL80211_SECURITY_WPA2_ENTERPRISE
            } else if rsnakms & ITL80211_AKM_PSK.rawValue != 0 {
                if rsnprotos & ITL80211_PROTO_WPA.rawValue != 0 {
                    return ITL80211_SECURITY_WPA_PERSONAL_MIXED
                }
                return ITL80211_SECURITY_WPA2_PERSONAL
            } else if rsnakms & ITL80211_AKM_SHA256_8021X.rawValue != 0 {
                return ITL80211_SECURITY_WPA2_ENTERPRISE
            } else if rsnakms & ITL80211_AKM_SHA256_PSK.rawValue != 0 {
                return ITL80211_SECURITY_PERSONAL
            }
        } else if rsnprotos & ITL80211_PROTO_WPA.rawValue != 0 {
            // WPA
            if rsnakms & ITL80211_AKM_8021X.rawValue != 0 {
                return ITL80211_SECURITY_WPA_ENTERPRISE
            } else if rsnakms & ITL80211_AKM_PSK.rawValue != 0 {
                return ITL80211_SECURITY_WPA_PERSONAL
            } else if rsnakms & ITL80211_AKM_SHA256_8021X.rawValue != 0 {
                return ITL80211_SECURITY_WPA_ENTERPRISE
            } else if rsnakms & ITL80211_AKM_SHA256_PSK.rawValue != 0 {
                return ITL80211_SECURITY_ENTERPRISE
            }
        } else if rsnprotos == 0 {
            return ITL80211_SECURITY_NONE
        }
        return ITL80211_SECURITY_UNKNOWN
    }

    private static func getRouterAddressFromNetstat(_ bsd: String) -> String? {
        var ipAddr: String?

        autoreleasepool {
            // from Goshin
            let ipAddressRegex = #"\s([a-fA-F0-9\.:]+)(\s|%)"# // for ipv4 and ipv6

            let routerCommand = ["-c", "netstat -rn", "|", "egrep -o", "default.*\(bsd)"]
            guard let routerOutput = Commands.execute(executablePath: .shell, args: routerCommand).0 else { return }
            let regex = try? NSRegularExpression.init(pattern: ipAddressRegex, options: [])
            let firstMatch = regex?.firstMatch(in: routerOutput,
                                               options: [],
                                               range: NSRange(location: 0, length: routerOutput.count))
            if let range = firstMatch?.range(at: 1) {
                if let swiftRange = Range(range, in: routerOutput) {
                    ipAddr = String(routerOutput[swiftRange])
                }
            } else {
                Log.debug("Could not find router ip address")
            }
        }

        return ipAddr
    }

    // Modified from https://stackoverflow.com/a/67780630 to support ipv6 and bsd filtering
    // See https://opensource.apple.com/source/network_cmds/network_cmds-606.40.2/netstat.tproj/route.c
    private static func getRouterAddressFromSysctl(_ bsd: String) -> String? {
        var mib: [Int32] = [CTL_NET,
                            PF_ROUTE,
                            0,
                            0,
                            NET_RT_DUMP2,
                            0]
        let mibSize = u_int(mib.count)

        var bufSize = 0
        sysctl(&mib, mibSize, nil, &bufSize, nil, 0)

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: bufSize)

        guard sysctl(&mib, mibSize, buf, &bufSize, nil, 0) == 0 else { return nil }

        // Routes
        var next = buf
        let lim = next.advanced(by: bufSize)
        while next < lim {
            let rtm = next.withMemoryRebound(to: rt_msghdr2.self, capacity: 1) { $0.pointee }
            var ifname = [CChar](repeating: 0, count: Int(IFNAMSIZ + 1))
            if_indextoname(UInt32(rtm.rtm_index), &ifname)

            if string(fromNullTerminatedCChars: ifname) == bsd, let addr = getRouterAddressFromRTM(rtm, next) {
                return addr
            }

            next = next.advanced(by: Int(rtm.rtm_msglen))
        }

        return nil
    }

    private static func getRouterAddressFromRTM(_ rtm: rt_msghdr2,
                                                _ ptr: UnsafeMutablePointer<UInt8>) -> String? {
        var rawAddr = ptr.advanced(by: MemoryLayout<rt_msghdr2>.stride)

        for idx in 0..<RTAX_MAX {
            let sockAddr = rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }

            if (rtm.rtm_addrs & (1 << idx)) != 0 && idx == RTAX_GATEWAY {
                switch Int32(sockAddr.sa_family) {
                case AF_INET:
                    let sAddr = rawAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }.sin_addr
                    // Take the first match, assuming its destination is "default"
                    return String(cString: inet_ntoa(sAddr), encoding: .ascii)
                case AF_INET6: // Not tested, maybe a garbage address from ipv4 will come first?
                    var sAddr6 = rawAddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }.sin6_addr
                    var addrV6 = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &sAddr6, &addrV6, socklen_t(INET6_ADDRSTRLEN))
                    return String(cString: addrV6, encoding: .ascii)
                default: break
                }
            }

            rawAddr = rawAddr.advanced(by: Int(sockAddr.sa_len))
        }

        return nil
    }

    private static func associationFailureDescription(_ status: ioctl_assoc_status) -> String? {
        let hasFailure = status.failure != ITL_ASSOC_FAIL_NONE ||
            status.deauth_reason != 0 && status.deauth_reason != 1 ||
            status.assoc_status != UInt16.max
        guard hasFailure else { return nil }

        var parts = [failureDescription(status.failure)]
        let ssid = String(ssid: status.ssid)
        if !ssid.isEmpty {
            parts.append(ssid)
        }
        if status.advertised_rsnakms != 0 || status.selected_rsnakms != 0 {
            parts.append("AKM \(akmDescription(status.advertised_rsnakms)) -> " +
                         akmDescription(status.selected_rsnakms))
        }
        if status.advertised_rsncaps != 0 {
            parts.append(pmfDescription(status.advertised_rsncaps))
        }
        if status.eapol_msg1_rx != 0 || status.eapol_msg2_tx != 0 ||
            status.eapol_msg3_rx != 0 || status.eapol_msg4_tx != 0 {
            parts.append("EAPOL \(status.eapol_msg1_rx)/\(status.eapol_msg2_tx)/" +
                         "\(status.eapol_msg3_rx)/\(status.eapol_msg4_tx)")
        }
        if status.deauth_reason != 0 && status.deauth_reason != 1 {
            parts.append("deauth \(status.deauth_reason)")
        }
        if status.assoc_status != UInt16.max && status.assoc_status != 0 {
            parts.append("assoc status \(status.assoc_status)")
        }
        return parts.joined(separator: "; ")
    }

    private static func failureDescription(_ failure: itl_assoc_failure) -> String {
        switch failure {
        case ITL_ASSOC_FAIL_ASSOC_REJECT:
            return "association rejected"
        case ITL_ASSOC_FAIL_DEAUTH:
            return "deauthenticated"
        case ITL_ASSOC_FAIL_4WAY_TIMEOUT:
            return "4-way handshake timeout"
        case ITL_ASSOC_FAIL_GROUP_KEY_TIMEOUT:
            return "group key handshake timeout"
        case ITL_ASSOC_FAIL_RSN_IE_MISMATCH:
            return "RSN IE mismatch"
        case ITL_ASSOC_FAIL_BAD_GROUP_CIPHER:
            return "bad group cipher"
        case ITL_ASSOC_FAIL_BAD_PAIRWISE_CIPHER:
            return "bad pairwise cipher"
        case ITL_ASSOC_FAIL_BAD_AKMP:
            return "bad AKM"
        case ITL_ASSOC_FAIL_RSN_CAPS:
            return "RSN capabilities mismatch"
        case ITL_ASSOC_FAIL_MFP_POLICY:
            return "PMF policy mismatch"
        case ITL_ASSOC_FAIL_EAPOL:
            return "EAPOL key processing failed"
        default:
            return "association failed"
        }
    }

    private static func akmDescription(_ akms: UInt32) -> String {
        var names = [String]()
        if akms & ITL80211_AKM_PSK.rawValue != 0 {
            names.append("PSK")
        }
        if akms & ITL80211_AKM_SHA256_PSK.rawValue != 0 {
            names.append("SHA256_PSK")
        }
        if akms & ITL80211_AKM_8021X.rawValue != 0 {
            names.append("802.1X")
        }
        if akms & ITL80211_AKM_SHA256_8021X.rawValue != 0 {
            names.append("SHA256_8021X")
        }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private static func pmfDescription(_ rsnCaps: UInt16) -> String {
        let mfpr = (rsnCaps & 0x0040) != 0
        let mfpc = (rsnCaps & 0x0080) != 0
        if mfpr {
            return "PMF required"
        }
        if mfpc {
            return "PMF capable"
        }
        return "PMF disabled"
    }

    private static func string(fromNullTerminatedCChars chars: [CChar]) -> String {
        let bytes = chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
