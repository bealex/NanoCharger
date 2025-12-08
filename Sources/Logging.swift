// Copyright (c) 2025 Alex Babaev. All rights reserved.

enum LogLevel: Int {
    case info = 1
    case debug = 2
}

func log(_ string: String, level: LogLevel = .debug) {
    guard configuration.isDebugEnabled, configuration.logEnabled(level) else { return }

    print(string)
}


