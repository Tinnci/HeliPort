//
//  BugReporter.swift
//  HeliPort
//
//  Created by Erik Bautista on 7/26/20.
//  Copyright © 2020 OpenIntelWireless. All rights reserved.
//

/*
 * This program and the accompanying materials are licensed and made available
 * under the terms and conditions of the The 3-Clause BSD License
 * which accompanies this distribution. The full text of the license may be found at
 * https://opensource.org/licenses/BSD-3-Clause
 */

import Cocoa
import OSLog
import IOKit

@MainActor
final class BugReporter {

    private static let openPanel: NSOpenPanel = {
        let openPanel = NSOpenPanel()

        openPanel.title = NSLocalizedString("Choose a folder to output the bug report")
        openPanel.message = NSLocalizedString("The bug report will be generated in the seleted folder")
        openPanel.showsResizeIndicator = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        return openPanel
    }()

    nonisolated private static func generateHeliPortLog() -> String {

        // MARK: HeliPort log

        let appIdentifier = Bundle.main.bundleIdentifier!

        if #available(OSX 10.15, *) {
            do {
                let logStore = try OSLogStore.local()
                let lastBoot = logStore.position(timeIntervalSinceLatestBoot: 0)
                let matchingPredicate = NSPredicate(format: "subsystem == '\(appIdentifier)'")
                let enumerator = try logStore.getEntries(with: [],
                                                         at: lastBoot,
                                                         matching: matchingPredicate)
                let allEntries = Array(enumerator)
                let osLogEntryLogObjects = allEntries.compactMap { $0 as? OSLogEntryLog }
                var entryStr = ""
                for item in osLogEntryLogObjects where item.subsystem == appIdentifier {
                    entryStr += "\n\(item.date);    \(item.subsystem);    \(item.category);    \(item.composedMessage)"
                }
                return entryStr
            } catch {
                Log.error("Could not generate bug report \(error)")
                return .heliportCouldNotGetLogs
            }
        } else {
            let appLogCommand = ["show", "--predicate",
                                      "(subsystem == '\(appIdentifier)')", "--info", "--last", "boot"]
            let appLog = Commands.execute(executablePath: .log, args: appLogCommand)
            if let stringVal = appLog.0, appLog.1 == 0 {
                return stringVal
            } else {
                return .scriptFailed
            }
        }
    }

    nonisolated private static func generateItlwmLog() -> String {
        var response: String?

        if KextInfo("as.lvs1974.DebugEnhancer").kextDidLoad() {
            // msgbuf size is sufficient, collect dmesg logs
            response = NSAppleScript(source:
                                     // swiftlint:disable line_length
                                     """
                                     do shell script \"sudo dmesg | grep -E \\"itlwm|Airport|IO80211|EAPOL\\"\" with administrator privileges
                                     """)!.executeAndReturnError(nil).stringValue
                                     // swiftlint:enable line_length
        } else {
            response = .msgbufInsufficient
        }

        return response ?? .scriptFailed
    }

    public static func generateBugReport() async {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "Unknown"
        let appBuildVer = Bundle.main.infoDictionary?["CFBundleVersion"] ?? "Unknown"
        let releaseChannel = Bundle.main.infoDictionary?["OIWReleaseChannel"] as? String ?? "Unknown"
        let releaseVersion = Bundle.main.infoDictionary?["OIWReleaseVersion"] as? String ?? "Unknown"
        let buildCommit = Bundle.main.infoDictionary?["OIWBuildCommit"] as? String ?? "Unknown"

        let appLog = await Task.detached(priority: .background) {
            return generateHeliPortLog()
        }.value

        if appLog == .heliportCouldNotGetLogs || appLog == .scriptFailed {
            let alert = CriticalAlert(
                message: NSLocalizedString("Error occurred while generating bug report."),
                informativeText: appLog == .heliportCouldNotGetLogs ?
                NSLocalizedString("Could not generate report for HeliPort.") :
                NSLocalizedString("Command failed to fetch logs for HeliPort."),
                options: [NSLocalizedString("Dismiss")],
                errorText: appLog
            )
            alert.show()
            return
        }

        // MARK: itlwm log

        var drv_info = ioctl_driver_info()
        _ = ioctl_get(Int32(IOCTL_80211_DRIVER_INFO.rawValue), &drv_info, MemoryLayout<ioctl_driver_info>.size)
        var itlwmVer = String(cCharArray: drv_info.driver_version)
        var itlwmFwVer = String(cCharArray: drv_info.fw_version)
        if itlwmVer.isEmpty { itlwmVer = "Unknown" }
        if itlwmFwVer.isEmpty { itlwmFwVer = "Unknown" }

        let itlwmLog = await Task.detached(priority: .background) {
            return generateItlwmLog()
        }.value

        if itlwmLog == .msgbufInsufficient || itlwmLog == .scriptFailed {
            let alert = CriticalAlert(
                message: NSLocalizedString("Error occurred while generating bug report."),
                informativeText: itlwmLog == .msgbufInsufficient ?
                NSLocalizedString("Make sure you have installed `DebugEnhancer.kext`" +
                                  " before collecting logs for itlwm.") :
                NSLocalizedString("Could not read logs for `itlwm`." +
                                  " Make sure you allow `HeliPort` to read logs when prompted."),
                options: [NSLocalizedString("Dismiss"), NSLocalizedString("Open Documentation")],
                helpAnchor: .dmesgHelpURL,
                errorText: itlwmLog
            )

            if alert.show() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: .dmesgHelpURL)!)
            }
            return
        }

        // MARK: Get itlwm name if loaded (itlwm or itlwmx)

        let itlwmName = await Task.detached(priority: .background) { () -> String? in
            let kextstatCommand = ["-c", "kextstat"]
            let itlwmLoadedOutput = Commands.execute(executablePath: .shell, args: kextstatCommand).0
            guard let itlwmLoadedOutput,
                  let regex = try? NSRegularExpression.init(pattern: "\\b(itlwm\\w*)\\b", options: []) else {
                return nil
            }
            let firstMatch = regex.firstMatch(in: itlwmLoadedOutput,
                                              options: [],
                                              range: NSRange(location: 0, length: itlwmLoadedOutput.count))
            if let range = firstMatch?.range(at: 1),
               let swiftRange = Range(range, in: itlwmLoadedOutput) {
                return String(itlwmLoadedOutput[swiftRange])
            }
            return nil
        }.value

        // MARK: Output String

        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS"
        let dateRan = "Time ran: \(formatter.string(from: date))"
        let osVersion = ProcessInfo().operatingSystemVersionString
        let appOutput = """
                        \(appLog)

                        \(dateRan)
                        HeliPort Version: \(appVersion) (Build \(appBuildVer))
                        HeliPort Release: \(releaseVersion) (\(releaseChannel), commit \(buildCommit))

                        macOS \(osVersion)
                        """
        let itlwmOutput = """
                          \(itlwmLog)

                          \(dateRan)
                          \(itlwmName != nil ?  "\(itlwmName!) loaded version: \(itlwmVer) (Firmware: \(itlwmFwVer))" :
                                "Kext not loaded")

                          macOS \(osVersion)
                          """

        let folderUrl = openPanel.runModal() == NSApplication.ModalResponse.OK ? openPanel.url : nil
        guard let folderUrl else {
            Log.error("Could not get path to store bug report.")
            let alert = CriticalAlert(
                message: NSLocalizedString("Could not get path to generate bug report."),
                options: ["Dismiss"]
            )
            alert.show()
            return
        }

        let reportDirName = "bugreport_\(UInt16.random(in: UInt16.min...UInt16.max))"
        let reportDirUrl = folderUrl.appendingPathComponent(reportDirName, isDirectory: true)
        let heliPortLogUrl = reportDirUrl.appendingPathComponent("HeliPort_logs.log")
        let itlwmLogUrl = reportDirUrl.appendingPathComponent("\(itlwmName ?? "itlwm")_logs.log")
        let zipName = reportDirName + ".zip"
        let zipPath = "\(folderUrl.path)/\(zipName)"
        let outputFolderPath = folderUrl.path
        let selectedFilePath = zipPath

        let outputExitCode = await Task.detached(priority: .background) { () -> Int32 in
            do {
                try FileManager.default.createDirectory(at: reportDirUrl,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
                try appOutput.write(to: heliPortLogUrl, atomically: true, encoding: .utf8)
                try itlwmOutput.write(to: itlwmLogUrl, atomically: true, encoding: .utf8)
            } catch {
                Log.error("\(error)")
                return -1
            }

            let zipCommand = ["-c", "cd \(outputFolderPath) && " +
                                    "zip -r -X -m \(zipName) \(reportDirName)"]
            return Commands.execute(executablePath: .shell, args: zipCommand).1
        }.value

        guard outputExitCode == 0 else {
            Log.error("Could not create zip file: Exit code: \(outputExitCode)")
            let alert = CriticalAlert(
                message: NSLocalizedString("Could not create zip file for generated logs."),
                options: [NSLocalizedString("Dismiss")]
            )
            alert.show()
            return
        }

        // MARK: Select zip file

        NSWorkspace.shared.selectFile(selectedFilePath,
                                      inFileViewerRootedAtPath: outputFolderPath)
    }
}

private extension String {

    // MARK: HeliPort Generation errors

    static let heliportCouldNotGetLogs = "HELIPORT-OSLOGSTORE"

    // MARK: ITLWM Generation errors

    static let msgbufInsufficient = "MSGBUF-INSUFFICIENT"
    static let scriptFailed = "SCRIPT-FAILED"

    // MARK: DOC URL
    static let dmesgHelpURL = "https://docs.oiw.workers.dev/itlwm/Troubleshooting.html#runtime-logs"
}
