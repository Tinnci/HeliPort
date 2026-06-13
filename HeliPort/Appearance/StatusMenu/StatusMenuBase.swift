//
//  StatusMenuBase.swift
//  HeliPort
//
//  Created by 梁怀宇 on 2020/4/5.
//  Copyright © 2020 OpenIntelWireless. All rights reserved.
//

/*
 * This program and the accompanying materials are licensed and made available
 * under the terms and conditions of the The 3-Clause BSD License
 * which accompanies this distribution. The full text of the license may be found at
 * https://opensource.org/licenses/BSD-3-Clause
 */

import Cocoa
import Sparkle

@MainActor
protocol StatusMenuItems {
    var enabledNetworkCardItems: [NSMenuItem] { get }
    var stationInfoItems: [NSMenuItem] { get }
    var hiddenItems: [NSMenuItem] { get }
    var notImplementedItems: [NSMenuItem] { get }

    func setupMenu()
    func setValueForItem(_ item: NSMenuItem, value: String)
    func updateNetworkList()
    func toggleWIFI()
}

@MainActor
class StatusMenuBase: NSMenu, NSMenuDelegate {

    // - MARK: Properties

    private let networkListUpdatePeriod: Double = 5
    private let statusUpdatePeriod: Double = 2

    var headerLength: Int = 0
    private var networkListUpdateTimer: Timer?
    private var statusUpdateTimer: Timer?

    private struct DeviceInfo: Sendable {
        var bsdName: String = .unavailable
        var macAddr: String = .unavailable
        var itlwmVer: String = .unavailable
        var shouldScanSavedNetworks: Bool = false
    }

    private struct StatusInfo: Sendable {
        let getPowerResult: Bool
        let getStateResult: Bool
        let powerState: Bool
        let status: UInt32
    }

    // One instance at a time
    private lazy var preferenceWindow = PrefsWindow()

    private var driverState: itl_80211_state = ITL80211_S_INIT {
        didSet {
            /** Only allow if network card is enabled or if the network card does not load
             either due to itlwm not loaded or just not able to receive info
             This prevents cards that are working but are "off" to not change the
             Status from "WiFi off" to another status. i.e "WiFi: on". */
            guard isNetworkCardEnabled || !isNetworkCardAvailable else { return }

            switch driverState {
            case ITL80211_S_INIT:
                StatusBarIcon.shared().disconnected()
            case ITL80211_S_AUTH, ITL80211_S_ASSOC:
                StatusBarIcon.shared().connecting()
            case ITL80211_S_RUN:
                Task { @MainActor in
                    let signal = await Task.detached(priority: .background) { () -> (Bool, Int16) in
                        let isReachable = NetworkManager.isReachable()
                        var staInfo = station_info_t()
                        get_station_info(&staInfo)
                        return (isReachable, staInfo.rssi)
                    }.value
                    guard signal.0 else { StatusBarIcon.shared().warning(); return }
                    StatusBarIcon.shared().signalStrength(rssi: signal.1)
                }
            case ITL80211_S_SCAN:
                /** API does not report bgscan to HeliPort. During `ITL80211_S_RUN` the status
                 will never change to `ITL80211_S_SCAN` unless users manually disassociate.
                 Set the icon to disconnected here so it displays correctly when users manually disassociate. */
                StatusBarIcon.shared().disconnected()
            default:
                StatusBarIcon.shared().error()
            }
        }
    }

    var showAllOptions: Bool = false {
        willSet(visible) {
            guard let items = self as? StatusMenuItems else { return }

            items.hiddenItems.forEach { $0.isHidden = !visible }
            items.enabledNetworkCardItems.forEach { $0.isHidden = !isNetworkCardAvailable }
            items.stationInfoItems.forEach { $0.isHidden = !(visible &&
                                                             self.isNetworkConnected &&
                                                             self.isNetworkCardEnabled) }
            items.notImplementedItems.forEach { $0.isHidden = true }
        }
    }

    var isNetworkConnected: Bool = false {
        willSet {
            guard isNetworkConnected != newValue, let items = self as? StatusMenuItems else { return }
            items.stationInfoItems.forEach { $0.isHidden = !newValue || !showAllOptions }
        }
    }

    var isNetworkListEmpty: Bool = true {
        willSet(empty) {
            guard empty else { return }
            currentNetworkItem.isHidden = true
        }
    }

    var isNetworkCardAvailable: Bool = true {
        willSet(newState) {
            if !newState && newState != isNetworkCardAvailable {
                self.isNetworkCardEnabled = false
            }
        }
    }

    var isNetworkCardEnabled: Bool = true {
        willSet(newState) {
            guard newState != isNetworkCardEnabled else { return }

            newState ? StatusBarIcon.shared().on() : StatusBarIcon.shared().off()

            if !newState {
                self.isNetworkListEmpty = true
                self.isNetworkConnected = false
            }
        }
    }

    private var isAutoLaunch: Bool = false {
        willSet(newState) {
            toggleLaunchItem.state = newState ? .on : .off
        }
    }

    // - MARK: Common Menu items

    let bsdItem = HPMenuItem(title: .interfaceName)
    let macItem = HPMenuItem(title: .macAddress)
    let itlwmVerItem = HPMenuItem(title: .itlwmVer)

    let enableLoggingItem = HPMenuItem(title: .enableWiFiLog)
    let createReportItem = HPMenuItem(title: .createReport)
    let diagnoseItem = HPMenuItem(title: .openDiagnostics)
    let hardwareInfoSeparator = NSMenuItem.separator()

    let networkItemListSeparator = NSMenuItem.separator()
    let lastAssociationFailureItem: HPMenuItem = {
        let item = HPMenuItem(title: .lastWiFiFailure)
        item.isHidden = true
        return item
    }()

    let aboutItem = HPMenuItem(title: .aboutHeliport)
    lazy var checkUpdateItem: HPMenuItem = {
         let item = HPMenuItem(title: .checkUpdates)
         item.target = UpdateManager.sharedController
         item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
         return item
     }()
    let quitSeparator = NSMenuItem.separator()
    let quitItem = HPMenuItem(title: .quitHeliport,
                              action: #selector(clickMenuItem(_:)), keyEquivalent: "q")

    let toggleLaunchItem = HPMenuItem(title: .launchLogin,
                                      action: #selector(clickMenuItem(_:)))

    // MARK: - WiFi connected items

    let currentNetworkItem = HPMenuItem(highlightable: true)
    let ipAddresssItem = HPMenuItem(title: .ipAddr)
    let routerItem = HPMenuItem(title: .routerStr)
    let internetItem = HPMenuItem(title: .internetStr)
    let securityItem = HPMenuItem(title: .securityStr)
    let bssidItem = HPMenuItem(title: .bssidStr)
    let channelItem = HPMenuItem(title: .channelStr)
    let countryCodeItem = HPMenuItem(title: .countryCodeStr)
    let rssiItem = HPMenuItem(title: .rssiStr)
    let noiseItem = HPMenuItem(title: .noiseStr)
    let txRateItem = HPMenuItem(title: .txRateStr)
    let phyModeItem = HPMenuItem(title: .phyModeStr)
    let mcsIndexItem = HPMenuItem(title: .mcsStr)
    let nssItem = HPMenuItem(title: .nssStr)

    // - MARK: Init

    init() {
        super.init(title: "")
    }

    func configure() {
        delegate = self
        isAutoLaunch = LoginItemManager.isEnabled()

        (self as? StatusMenuItems)?.setupMenu()
        getDeviceInfo()

        statusUpdateTimer = Timer.scheduledTimer(
            timeInterval: statusUpdatePeriod,
            target: self,
            selector: #selector(updateStatus),
            userInfo: nil,
            repeats: true
        )
        statusUpdateTimer?.fire()

        NSApp.servicesProvider = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // - MARK: NSMenuDelegate

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        (menu.highlightedItem?.view as? SelectableMenuItemView)?.isMouseOver = false
        (item?.view as? SelectableMenuItemView)?.isMouseOver = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        showAllOptions = (NSApp.currentEvent?.modifierFlags.contains(.option)) ?? false

        updateStationItems()
        networkListUpdateTimer = Timer.scheduledTimer(
            timeInterval: networkListUpdatePeriod,
            target: self,
            selector: #selector(updateNetworkList),
            userInfo: nil,
            repeats: true
        )
        networkListUpdateTimer?.fire()
    }

    func menuDidClose(_ menu: NSMenu) {
        networkListUpdateTimer?.invalidate()
        (menu.highlightedItem?.view as? SelectableMenuItemView)?.isMouseOver = false
    }

    // - MARK: Actions

    func addClickItem(_ item: NSMenuItem) {
        item.target = item.target ?? self
        item.action = item.action ?? #selector(clickMenuItem(_:))
        addItem(item)
    }

    func addNetworkItem(_ item: NSMenuItem = HPMenuItem(highlightable: true),
                        insertAt: Int? = nil,
                        hidden: Bool = false,
                        networkInfo: NetworkInfo = NetworkInfo(ssid: "placeholder")) -> NSMenuItem {
        item.isHidden = hidden

        if let insertAt {
            insertItem(item, at: insertAt)
        } else {
            addItem(item)
        }

        return item
    }

    private func getDeviceInfo() {
        Task { @MainActor in
            let deviceInfo = await Task.detached(priority: .background) { () -> DeviceInfo in
                var deviceInfo = DeviceInfo()
                var platformInfo = platform_info_t()

                if is_power_on() {
                    Log.debug("Wi-Fi powered on")
                } else {
                    Log.debug("Wi-Fi powered off")
                }

                if get_platform_info(&platformInfo) {
                    deviceInfo.bsdName = String(cCharArray: platformInfo.device_info_str)
                    deviceInfo.macAddr = NetworkManager.getMACAddressFromBSD(bsd: deviceInfo.bsdName) ??
                        deviceInfo.macAddr
                    deviceInfo.itlwmVer = String(cCharArray: platformInfo.driver_info_str)
                }

                // If not connected, try to connect saved networks
                var stationInfo = station_info_t()
                var state: UInt32 = 0
                var power: Bool = false
                get_power_state(&power)
                let shouldScanSavedNetworks = get_80211_state(&state) && power &&
                    (state != ITL80211_S_RUN.rawValue || get_station_info(&stationInfo) != KERN_SUCCESS)
                deviceInfo.shouldScanSavedNetworks = shouldScanSavedNetworks
                return deviceInfo
            }.value

            if let items = self as? StatusMenuItems {
                items.setValueForItem(self.bsdItem, value: deviceInfo.bsdName)
                items.setValueForItem(self.macItem, value: deviceInfo.macAddr)
                items.setValueForItem(self.itlwmVerItem, value: deviceInfo.itlwmVer)
            }

            if deviceInfo.shouldScanSavedNetworks {
                NetworkManager.scanSavedNetworks()
            }
        }
    }

    // - MARK: Action handlers

    @objc func clickMenuItem(_ sender: NSMenuItem) {
        Log.debug("Clicked \(sender.title)")
        switch sender.title {
        case .createReport:
            // Disable while bug report is being genetated, if autoenable == true, NSMenu ignores isEnable
            createReportItem.action = nil
            Task { @MainActor in
                await BugReporter.generateBugReport()
                // Enable after generating report is finished
                self.createReportItem.action = #selector(self.clickMenuItem(_:))
            }
        case .Legacy.turnWiFiOn:
            power_on()
        case .Legacy.turnWiFiOff:
            power_off()
        case .Legacy.joinNetworks, .Modern.joinNetworks:
            let joinPop = WiFiConfigWindow()
            joinPop.show()
        case .Legacy.createNetwork:
            let alert = Alert(text: .notImplemented)
            alert.show()
        case .Legacy.openNetworkPrefs, .Modern.wifiSettings:
            preferenceWindow.close()
            preferenceWindow.show()
        case .launchLogin:
            LoginItemManager.setStatus(enabled: !LoginItemManager.isEnabled())
            isAutoLaunch = LoginItemManager.isEnabled()
        case .aboutHeliport:
            NSApplication.shared.orderFrontStandardAboutPanel()
            NSApplication.shared.activate(ignoringOtherApps: true)
        case .quitHeliport:
            NSApp.terminate(nil)
        default:
            Log.error("Invalid menu item clicked")
        }
    }

    @objc private func updateStatus() {
        Task { @MainActor in
            let statusInfo = await Task.detached(priority: .background) { () -> StatusInfo in
                var powerState: Bool = false
                let getPowerResult = get_power_state(&powerState)
                var status: UInt32 = 0xFF
                let getStateResult = get_80211_state(&status)

                return StatusInfo(
                    getPowerResult: getPowerResult,
                    getStateResult: getStateResult,
                    powerState: powerState,
                    status: status
                )
            }.value

            if statusInfo.getPowerResult && statusInfo.getStateResult {
                self.isNetworkCardEnabled = statusInfo.powerState
            } else {
                Log.error("Failed get card state")
            }
            self.isNetworkCardAvailable = statusInfo.getPowerResult
            self.driverState = itl_80211_state(rawValue: statusInfo.status)
            self.updateStationItems()
        }
    }

    struct StationInfo: Sendable {
        var ssid: String?
        var rssiValue: Int = 0
        var ipAddr: String = .unavailable
        var routerAddr: String = .unavailable
        var internet: String = .unavailable
        var security: String = .unavailable
        var securityMode: itl80211_security = ITL80211_SECURITY_NONE
        var bssid: String = .unavailable
        var channel: String = .unavailable
        var countryCode: String = .unavailable
        var rssi: String = .unavailable
        var noise: String = .unavailable
        var txRate: String = .unavailable
        var phyMode: String = .unavailable
        var mcsIndex: String = .unavailable
        var nss: String = .unavailable
        var isNetworkConnected = false
    }

    func updateStationItems() {
        guard isNetworkCardEnabled else { return }

        Task { @MainActor in
            let info = await self.getStationInfo()
            self.setCurrentNetworkItem(with: info)
            self.setStationItems(with: info)
            await self.updateLastAssociationFailureItem()
        }
    }

    private func getStationInfo() async -> StationInfo {
        let driverState = driverState
        let showAllOptions = showAllOptions
        return await Task.detached(priority: .background) {
            var infoOut = StationInfo()
            var infoIn = station_info_t()

            guard driverState == ITL80211_S_RUN,
                  get_station_info(&infoIn) == KERN_SUCCESS else {
                return infoOut
            }

            infoOut.isNetworkConnected = true
            infoOut.ssid = String(ssid: infoIn.ssid)
            infoOut.rssiValue = Int(infoIn.rssi)

            var assocStatus = ioctl_assoc_status()
            if get_assoc_status(&assocStatus) {
                infoOut.securityMode = NetworkManager.getSecurityType(assocStatus)
            }

            guard showAllOptions else { return infoOut }

            var platformInfo = platform_info_t()
            if get_platform_info(&platformInfo) {
                let bsd = String(cCharArray: platformInfo.device_info_str)
                infoOut.ipAddr = NetworkManager.getLocalAddress(bsd: bsd) ?? .unknown
                infoOut.routerAddr = NetworkManager.getRouterAddress(bsd: bsd) ?? .unknown
            }

            infoOut.internet = NetworkManager.isReachable() ? .reachable : .unreachable
            infoOut.security = .unknown
            infoOut.bssid = String(format: "%02x:%02x:%02x:%02x:%02x:%02x",
                                   infoIn.bssid.0,
                                   infoIn.bssid.1,
                                   infoIn.bssid.2,
                                   infoIn.bssid.3,
                                   infoIn.bssid.4,
                                   infoIn.bssid.5)
            infoOut.channel = "\(infoIn.channel) (\(infoIn.channel <= 14 ? 2.4 : 5) GHz, \(infoIn.band_width) MHz)"
            infoOut.countryCode = .unknown
            infoOut.rssi = "\(infoIn.rssi) dBm"
            infoOut.noise = "\(infoIn.noise) dBm"
            infoOut.txRate = "\(infoIn.rate) Mbps"
            infoOut.phyMode = infoIn.op_mode.description
            infoOut.mcsIndex = "\(infoIn.cur_mcs)"
            infoOut.nss = .unknown

            return infoOut
        }.value
    }

    func setStationItems(with info: StationInfo) {
        guard showAllOptions, let items = self as? StatusMenuItems else { return }

        items.setValueForItem(self.ipAddresssItem, value: info.ipAddr)
        items.setValueForItem(self.routerItem, value: info.routerAddr)
        items.setValueForItem(self.internetItem, value: info.internet)
        items.setValueForItem(self.securityItem, value: info.security)
        items.setValueForItem(self.bssidItem, value: info.bssid)
        items.setValueForItem(self.channelItem, value: info.channel)
        items.setValueForItem(self.countryCodeItem, value: info.countryCode)
        items.setValueForItem(self.rssiItem, value: info.rssi)
        items.setValueForItem(self.noiseItem, value: info.noise)
        items.setValueForItem(self.txRateItem, value: info.txRate)
        items.setValueForItem(self.phyModeItem, value: info.phyMode)
        items.setValueForItem(self.mcsIndexItem, value: info.mcsIndex)
        items.setValueForItem(self.nssItem, value: info.nss)
    }

    func setCurrentNetworkItem(with info: StationInfo) {
        isNetworkConnected = info.isNetworkConnected

        guard isNetworkCardEnabled,
              let wifiItemView = currentNetworkItem.view as? WifiMenuItemView else { return }

        // disconnected -> connected
        if !wifiItemView.connected && info.isNetworkConnected {
            for index in self.headerLength ..< self.items.count {
                if let view = self.items[index].view as? WifiMenuItemView,
                   view.networkInfo.ssid == info.ssid {
                    self.items[index].isHidden = true
                    self.items[index].isEnabled = false
                    break
                }
            }
        }

        currentNetworkItem.isHidden = !isNetworkConnected
        wifiItemView.connected = isNetworkConnected

        guard isNetworkConnected else { return }

        isNetworkListEmpty = false
        if let staSSID = info.ssid, wifiItemView.networkInfo.ssid != staSSID {
            var networkInfo = NetworkInfo(ssid: staSSID, rssi: info.rssiValue)
            networkInfo.auth.security = info.securityMode
            wifiItemView.networkInfo = networkInfo
        } else {
            var networkInfo = wifiItemView.networkInfo
            networkInfo.rssi = info.rssiValue
            if networkInfo.auth.security == ITL80211_SECURITY_NONE {
                networkInfo.auth.security = info.securityMode
            }
            wifiItemView.networkInfo = networkInfo
            wifiItemView.updateImages()
        }
    }

    func updateLastAssociationFailureItem() async {
        guard let items = self as? StatusMenuItems else { return }
        let failure = await NetworkManager.lastAssociationFailure()
        lastAssociationFailureItem.isHidden = isNetworkConnected || failure == nil
        items.setValueForItem(lastAssociationFailureItem, value: failure ?? "")
    }

    func processNetworkList(from infoList: [NetworkInfo], to itemList: inout [NSMenuItem],
                            insertAt: Int, _ staInfo: NetworkInfo?, hidden: Bool = false) {
        var index = 0

        for info in infoList {
            var enabled = true

            if let staInfo, staInfo.ssid == info.ssid {
                var currentNetworkInfo = staInfo
                currentNetworkInfo.auth.security = info.auth.security
                (self.currentNetworkItem.view as? WifiMenuItemView)?.networkInfo = currentNetworkInfo
                (self.currentNetworkItem.view as? WifiMenuItemView)?.updateImages()
                enabled = false
            }

            if index < itemList.endIndex, let wifiMenuItemView = itemList[index].view as? WifiMenuItemView {
                // Reuse existing item
                itemList[index].isHidden = hidden || !enabled
                itemList[index].isEnabled = enabled
                wifiMenuItemView.networkInfo = info
            } else {
                // Add new item if not enough existing ones
                let item = self.addNetworkItem(insertAt: insertAt + index,
                                               hidden: hidden || !enabled,
                                               networkInfo: info)
                item.isEnabled = enabled
                itemList.append(item)
            }

            index += 1
        }

        // Hide extra items
        for hideIndex in (index..<itemList.count).reversed() {
            itemList[hideIndex].isEnabled = false
            itemList[hideIndex].isHidden = true
        }
    }

    @objc private func updateNetworkList() {
        (self as? StatusMenuItems)?.updateNetworkList()
    }

    @objc func toggleWiFiServiceHandler(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        Log.debug("Handle Toggle WiFi service")
        (self as? StatusMenuItems)?.toggleWIFI()
    }
}

// MARK: Localized Strings

private extension String {
    static let notImplemented = NSLocalizedString("FUNCTION NOT IMPLEMENTED")
    static let unknown = NSLocalizedString("Unknown")
    static let unavailable = NSLocalizedString("Unavailable")
    static let interfaceName = NSLocalizedString("Interface Name: ")
    static let macAddress = NSLocalizedString("Address: ")
    static let itlwmVer = NSLocalizedString("Version: ")
    static let enableWiFiLog = NSLocalizedString("Enable Wi-Fi Logging")
    static let createReport = NSLocalizedString("Create Diagnostics Report...")
    static let openDiagnostics = NSLocalizedString("Open Wireless Diagnostics...")
    static let checkUpdates = NSLocalizedString("Check for Updates...")
    static let aboutHeliport = NSLocalizedString("About HeliPort")
    static let quitHeliport = NSLocalizedString("Quit HeliPort")
    static let launchLogin = NSLocalizedString("Launch At Login")
    static let ipAddr = NSLocalizedString("    IP Address: ")
    static let routerStr = NSLocalizedString("    Router: ")
    static let internetStr = NSLocalizedString("    Internet: ")
    static let reachable = NSLocalizedString("Reachable")
    static let unreachable = NSLocalizedString("Unreachable")
    static let securityStr = NSLocalizedString("    Security: ")
    static let lastWiFiFailure = NSLocalizedString("Last Wi-Fi Failure: ")
    static let bssidStr = NSLocalizedString("    BSSID: ")
    static let channelStr = NSLocalizedString("    Channel: ")
    static let countryCodeStr = NSLocalizedString("    Country Code: ")
    static let rssiStr = NSLocalizedString("    RSSI: ")
    static let noiseStr = NSLocalizedString("    Noise: ")
    static let txRateStr = NSLocalizedString("    Tx Rate: ")
    static let phyModeStr = NSLocalizedString("    PHY Mode: ")
    static let mcsStr = NSLocalizedString("    MCS Index: ")
    static let nssStr = NSLocalizedString("    NSS: ")
}

extension String {
    enum Legacy {
        static let statusUnavailable = NSLocalizedString("Wi-Fi: Status unavailable")
        static let turnWiFiOn = NSLocalizedString("Turn Wi-Fi On")
        static let turnWiFiOff = NSLocalizedString("Turn Wi-Fi Off")
        static let wifiOn = NSLocalizedString("Wi-Fi: On")
        static let wifiOff = NSLocalizedString("Wi-Fi: Off")
        static let joinNetworks = NSLocalizedString("Join Other Network...")
        static let createNetwork = NSLocalizedString("Create Network...")
        static let openNetworkPrefs = NSLocalizedString("Open Network Preferences...")
        static let disconnectNet = NSLocalizedString("Disconnect from ")
    }

    enum Modern {
        static let wifi = NSLocalizedString("Wi-Fi")
        static let knownNetwork = NSLocalizedString("Known Network")
        static let knownNetworks = NSLocalizedString("Known Networks")
        static let otherNetworks = NSLocalizedString("Other Networks")
        static let joinNetworks = NSLocalizedString("Other...")
        static let wifiSettings = NSLocalizedString("Wi-Fi Settings...")
    }
}
