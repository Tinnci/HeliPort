//
//  String+NonNullTerminated.swift
//  HeliPort
//
//  Created by Erik Bautista on 11/21/20.
//  Copyright © 2020 OpenIntelWireless. All rights reserved.
//

/*
 * This program and the accompanying materials are licensed and made available
 * under the terms and conditions of the The 3-Clause BSD License
 * which accompanies this distribution. The full text of the license may be found at
 * https://opensource.org/licenses/BSD-3-Clause
 */

import Foundation

public extension String {
    enum DefaultsKey {
        static let legacyUI = "legacyUIEnabled"
    }

    init<T>(ssid: T) {
        self = withUnsafeBytes(of: ssid) {
            String(bytes: $0.prefix(Int(NWID_LEN)), encoding: .utf8) ?? ""
        }.trimmingCharacters(in: .whitespaces)
         .replacingOccurrences(of: "\0", with: "")
        self.unicodeScalars.removeAll(where: { CharacterSet.newlines.contains($0) })
    }

    init<T>(cCharArray: T) {
        self = withUnsafeBytes(of: cCharArray) {
            let bytes = Array($0.prefix { $0 != 0 })
            if let string = String(bytes: bytes, encoding: .utf8) {
                return string
            }

            let printableASCII = bytes.filter { byte in
                byte >= 0x20 && byte < 0x7f
            }
            return String(bytes: printableASCII, encoding: .utf8) ?? ""
        }
    }
}
