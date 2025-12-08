// Copyright (c) 2025 Alex Babaev. All rights reserved.

import Foundation
import Subprocess

@main
struct NanoCharger {
    final class ChargingState {
        var connectedDevices: [UsbDevice: UsbConnection] = [:]
        var chargingQueue: [UsbDevice] = []

        var currentChargingDevice: UsbDevice?
        var currentChargingDeviceChargingStartedTime: TimeInterval?

        /**
         - structures:
           - connected devices: dictionary, by the hub/port connection
           - charging queue: FIFO (add to the tail, get from the head)
           - current charging device, device charging start time

         - if a device is connected (and was disconnected)
           - add it to connected devices
           - add it to the charging queue
           - disable charging for the port
         - if any device is disconnected (and was connected)
           - if it was charging, set charging device to nil
           - remove it from connected devices
           - remove it from the charging queue
         - if charging device is not nil
           - check charging time, if it is longer than max charging time:
             - set charging device to nil
         - if charging device is nil
           - get the next device from the charging queue
           - turn on the charging for it
           - set it as a charging device
           - move charging device to the tail of the charging queue
         */

        func updateDevices(configuration: Configuration) async throws {
            let currentConnectedDevices = try await UsbDevice.connectedUsbDevices()
            let currentTime = Date.timeIntervalSinceReferenceDate

            // device connected
            for (device, connection) in currentConnectedDevices where !connectedDevices.keys.contains(device) {
                connectedDevices[device] = connection
                chargingQueue.append(device)
                try await connection.stopCharging()
            }

            // device disconnected
            for (device, connection) in connectedDevices where !currentConnectedDevices.keys.contains(device) {
                connectedDevices[device] = nil
                chargingQueue = chargingQueue.filter { $0 != device }
                if currentChargingDevice == device {
                    currentChargingDevice = nil
                }
            }

            // some device is charging
            if let device = currentChargingDevice, let chargeStartTime = currentChargingDeviceChargingStartedTime, let connection = connectedDevices[device] {
                if currentTime - chargeStartTime > configuration.chargingDuration {
                    currentChargingDevice = nil
                    try await connection.stopCharging()
                }
            }

            // no devices are charging
            if currentChargingDevice == nil, !chargingQueue.isEmpty {
                let device = chargingQueue.removeFirst()
                if let connection = connectedDevices[device] {
                    currentChargingDevice = device
                    currentChargingDeviceChargingStartedTime = currentTime
                    try await connection.stopCharging()
                }
            }

//            let devicesChanged = updatedDevices.elementsEqual(devices)
        }
    }

    private func chargingLoop() async {
        let state = ChargingState()

        while true {
            try? await Task.sleep(for: .seconds(60))
            do {
                try await state.updateDevices(configuration: configuration)
            } catch {

            }
        }
    }

    static func main() async {
        log("Start")

        do {
            let devices = try await UsbDevice.connectedUsbDevices()
            print(devices.map { "\($0.value.hubId); \($0.value.portId) -> \($0.key.deviceId); \($0.key.deviceName); \($0.key.deviceUUID)" }.joined(separator: "\n"))
        } catch {
            log("Error \(error)")
        }

        log("Finish")
    }
}

