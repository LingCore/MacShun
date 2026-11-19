// SPDX-License-Identifier: MIT

import Foundation

/// 用锁保护的值。事件拦截线程和界面线程之间共享配置、当前应用等状态时使用。
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func withLock<R>(_ body: (Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(value)
    }

    @discardableResult
    func update<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
