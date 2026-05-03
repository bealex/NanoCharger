// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation

struct Configuration: Sendable {
    let isDebugEnabled: Bool
    let logLevel: LogLevel

    func logEnabled(_ level: LogLevel) -> Bool {
        level.rawValue <= logLevel.rawValue
    }
}

let configuration: Configuration = .init(isDebugEnabled: true, logLevel: .info)
