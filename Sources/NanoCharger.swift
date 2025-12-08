// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess

@main
struct NanoCharger {
    final class ChargingState {
        var devices: [UsbDevice] = []

        var lastChargedDevices: [UsbDevice] = []
        var lastChargingStartTime: TimeInterval = 0

        func updateDevices() async throws {
            let updatedDevices = try await UsbDevice.connectedUsbDevices()
            let devicesChanged = updatedDevices.elementsEqual(devices)
        }
    }

    private func chargingLoop() async {
        let state = ChargingState()

        while true {
            try? await Task.sleep(for: .seconds(60))
            do {
                try await state.updateDevices()
            } catch {

            }
        }
    }

    static func main() async {
        log("Start")

        do {
            let devices = try await UsbDevice.connectedUsbDevices()
            print(devices.map { "\($0.hubId); \($0.portId) -> \($0.deviceId); \($0.deviceName)" }.joined(separator: "\n"))
        } catch {
            log("Error \(error)")
        }

        log("Finish")
    }
}

