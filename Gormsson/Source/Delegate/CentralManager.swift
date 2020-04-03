//
//  CentralManager.swift
//  Gormsson
//
//  Created by Mac on 05/11/2019.
//  Copyright © 2019 Loïc GRIFFIE. All rights reserved.
//

import CoreBluetooth
import Nevanlinna

internal final class CentralManager: NSObject {
    private var cbManager: CBCentralManager?
    private var peripheralManager: PeripheralManager?

    // Auto scan logic if needed
    private var needScan = false
    private var scanServices: [GattService]?
    private var scanOptions: [String: Any]?

    /// The current state of the manager.
    private var state: GormssonState = .unknown {
        didSet {
            guard distinctState else {
                stateBlock?(state)
                return
            }

            if oldValue != state {
                stateBlock?(state)
            }
        }
    }
    /// The block to call each time the state change.
    private var stateBlock: ((GormssonState) -> Void)?
    /// Only notify value change if distinct.
    private var distinctState = false

    /// Dictionary of all connect handler.
    internal var connectHandlers = [UUID: ConnectHandler]()
    /// The block to call each time a peripheral is found.
    internal var didDiscover: ((Result<(CBPeripheral, GattAdvertisement), Error>) -> Void)?

    /// The pending requests that wait to be resolved.
    internal var pendingRequests = [GattRequest]()
    /// The current active requests (read / notify / write with response requests).
    internal var currentRequests = [GattRequest]()

    internal init(queue: DispatchQueue? = nil, options: [String: Any]? = nil) {
        super.init()
        cbManager = CBCentralManager(delegate: self, queue: queue, options: options)
        peripheralManager = PeripheralManager(self)
    }

    internal func observe(options: [ValueObservingOptions]? = nil, _ stateBlock: @escaping (GormssonState) -> Void) {
        self.stateBlock = stateBlock

        guard let options = options else { return }

        if options.contains(.initial) {
            stateBlock(state)
        }
        if options.contains(.distinct) {
            distinctState = true
        }
    }

    internal func updateState(with cbState: CBManagerState) {
        switch cbState {
        case .poweredOn:
            state = .isPoweredOn
            rescan()
        default:
            if state == .isPoweredOn {
                state = .didLostBluetooth
            } else {
                state = .needBluetooth
            }
        }
    }

    internal func scan(_ services: [GattService]? = nil,
                       options: [String: Any]? = nil,
                       didDiscover: @escaping (Result<(CBPeripheral, GattAdvertisement), Error>) -> Void) {
        guard !(cbManager?.isScanning ?? true) else {
            didDiscover(.failure(GormssonError.alreadyScanning))
            return
        }
        self.didDiscover = didDiscover
        guard state == .isPoweredOn else {
            needScan = true
            scanServices = services
            scanOptions = options
            return
        }

        cbManager?.scanForPeripherals(withServices: services?.map({ $0.uuid }), options: options)
    }

    internal func stopScan() {
        cbManager?.stopScan()
    }

    internal func connect(_ peripheral: CBPeripheral,
                          shouldStopScan: Bool = false,
                          success: (() -> Void)? = nil,
                          failure: ((Error?) -> Void)? = nil,
                          didReadyHandler: (() -> Void)? = nil,
                          didDisconnectHandler: ((Error?) -> Void)? = nil) {
        if shouldStopScan, cbManager?.isScanning ?? false {
            stopScan()
        }
        connectHandlers[peripheral.identifier] = ConnectHandler(didConnect: success,
                                                                didFailConnect: failure,
                                                                didReady: didReadyHandler,
                                                                didDisconnect: didDisconnectHandler)

        cbManager?.connect(peripheral)
        peripheral.delegate = self.peripheralManager
    }

    /// Gets the CBCharacteristic of the current peripheral or nil if not in.
    internal func get(_ characteristic: CharacteristicProtocol, on peripheral: CBPeripheral) -> CBCharacteristic? {
        return peripheral.services?.first(where: { $0.uuid == characteristic.service.uuid })?
            .characteristics?.first(where: { $0.uuid == characteristic.uuid })
    }

    /// Reads the value of a custom characteristic.
    internal func read(_ characteristic: CharacteristicProtocol,
                       on peripheral: CBPeripheral,
                       result: @escaping (Result<DataInitializable, Error>) -> Void) {
        guard state == .isPoweredOn else {
            result(.failure(GormssonError.powerOff))
            return
        }

        let request = GattRequest(.read, on: peripheral, characteristic: characteristic, result: result)

        guard peripheral.state == .connected else {
            guard peripheral.state == .connecting else {
                result(.failure(GormssonError.deviceDisconnected))
                return
            }
            pendingRequests.append(request)
            return
        }

        read(request)
    }

    /// Starts notifications or indications for the value of a base characteristic.
    internal func notify(_ characteristic: CharacteristicProtocol,
                         on peripheral: CBPeripheral,
                         result: @escaping (Result<DataInitializable, Error>) -> Void) {
        guard state == .isPoweredOn else {
            result(.failure(GormssonError.powerOff))
            return
        }

        let request = GattRequest(.notify, on: peripheral, characteristic: characteristic, result: result)

        guard peripheral.state == .connected else {
            guard peripheral.state == .connecting else {
                result(.failure(GormssonError.deviceDisconnected))
                return
            }
            guard !pendingRequests.contains(request) else {
                request.result?(.failure(GormssonError.alreadyNotifying))
                return
            }

            pendingRequests.append(request)
            return
        }

        notify(request)
    }

    /// Stops notifications or indications for the value of a custom characteristic.
    internal func stopNotify(_ characteristic: CharacteristicProtocol,
                             on peripheral: CBPeripheral) {
        guard let cbCharacteristic = get(characteristic, on: peripheral), cbCharacteristic.isNotifying else { return }

        peripheral.setNotifyValue(false, for: cbCharacteristic)
    }

    /// Writes the value of a custom characteristic.
    internal func write(_ characteristic: CharacteristicProtocol,
                        on peripheral: CBPeripheral,
                        value: DataConvertible,
                        type: CBCharacteristicWriteType = .withResponse,
                        result: @escaping (Result<DataInitializable, Error>) -> Void) {
        guard state == .isPoweredOn else {
            result(.failure(GormssonError.powerOff))
            return
        }

        let request = GattRequest(.write, on: peripheral, characteristic: characteristic, result: result)

        guard peripheral.state == .connected else {
            guard peripheral.state == .connecting else {
                result(.failure(GormssonError.deviceDisconnected))
                return
            }
            result(.failure(GormssonError.notReady))
            return
        }

        write(request, value: value, type: type)
    }

    internal func didDiscoverCharacteristics(on peripheral: CBPeripheral) {
        if peripheral.state == .connected {
            connectHandlers[peripheral.identifier]?.didReady?()
            let filter: ((GattRequest) -> Bool) = { $0.peripheral == peripheral }
            pendingRequests.filter(filter).forEach { request in
                switch request.property {
                case .read:
                    read(request)
                case .notify:
                    notify(request)
                default:
                    break
                }
            }
            pendingRequests.removeAll(where: filter)
        }
    }

    /// Send a new scan if the first one was too early.
    internal func rescan() {
        if needScan, let block = didDiscover {
            scan(scanServices, options: scanOptions, didDiscover: block)
            needScan = false
            scanServices = nil
            scanOptions = nil
        }
    }

    internal func cancel(_ peripheral: CBPeripheral) {
        cbManager?.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Private functions

    private func read(_ request: GattRequest,
                      append: Bool = true) {
        guard state == .isPoweredOn else {
            request.result?(.failure(GormssonError.powerOff))
            return
        }

        guard let cbCharacteristic = get(request.characteristic, on: request.peripheral) else {
            request.result?(.failure(GormssonError.characteristicNotFound))
            return
        }

        request.peripheral.readValue(for: cbCharacteristic)

        if append {
            currentRequests.append(request)
        }
    }

    /// Starts notifications for the value of a characteristic from a request.
    private func notify(_ request: GattRequest) {
        guard state == .isPoweredOn else {
            request.result?(.failure(GormssonError.powerOff))
            return
        }

        guard let cbCharacteristic = get(request.characteristic, on: request.peripheral) else {
            request.result?(.failure(GormssonError.characteristicNotFound))
            return
        }

        guard !cbCharacteristic.isNotifying, !currentRequests.contains(request) else {
            request.result?(.failure(GormssonError.alreadyNotifying))
            return
        }

        request.peripheral.setNotifyValue(true, for: cbCharacteristic)
        currentRequests.append(request)
    }

    /// Writes the value of a characteristic from a request.
    private func write(_ request: GattRequest,
                       value: DataConvertible,
                       type: CBCharacteristicWriteType = .withResponse) {
        guard state == .isPoweredOn else {
            request.result?(.failure(GormssonError.powerOff))
            return
        }

        guard let cbCharacteristic = get(request.characteristic, on: request.peripheral) else {
            request.result?(.failure(GormssonError.characteristicNotFound))
            return
        }

        request.peripheral.writeValue(value.toData(),
                              for: cbCharacteristic,
                              type: type)

        guard type == .withResponse else {
            request.result?(.success(Empty()))
            return
        }

        currentRequests.append(request)
    }
}
