// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation

enum LogLevel: Int, Sendable {
    case info = 1
    case debug = 2
}

func log(_ string: String, level: LogLevel = .debug) {
    guard configuration.isDebugEnabled, configuration.logEnabled(level) else { return }
    FileHandle.standardError.write(Data((string + "\n").utf8))
}
