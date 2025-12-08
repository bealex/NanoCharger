// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation

struct Configuration {
    let isDebugEnabled: Bool = true
    let logLevel: LogLevel = .info

    var chargingDuration: TimeInterval

    func logEnabled(_ level: LogLevel) -> Bool {
        level.rawValue <= logLevel.rawValue
    }
}

let configuration: Configuration = .init(
    chargingDuration: 2 * 60 * 60 // 2 hours
)
