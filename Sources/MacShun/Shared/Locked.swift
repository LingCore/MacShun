// SPDX-License-Identifier: MIT

import Foundation
import os

/// 用锁保护的值。事件拦截线程和界面线程之间共享配置、当前应用等状态时使用。
final class Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        self.lock = OSAllocatedUnfairLock(uncheckedState: value)
    }

    func get() -> Value {
        lock.withLockUnchecked { $0 }
    }

    func set(_ newValue: Value) {
        lock.withLockUnchecked { $0 = newValue }
    }

    func withLock<R>(_ body: (Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked { try body($0) }
    }

    @discardableResult
    func update<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked { try body(&$0) }
    }
}
