// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// macOS 虚拟键码（按键的物理位置，以美式键盘为准）。
enum KeyCode {
    static let a: CGKeyCode = 0x00
    static let s: CGKeyCode = 0x01
    static let d: CGKeyCode = 0x02
    static let f: CGKeyCode = 0x03
    static let h: CGKeyCode = 0x04
    static let g: CGKeyCode = 0x05
    static let z: CGKeyCode = 0x06
    static let x: CGKeyCode = 0x07
    static let c: CGKeyCode = 0x08
    static let v: CGKeyCode = 0x09
    static let b: CGKeyCode = 0x0B
    static let q: CGKeyCode = 0x0C
    static let w: CGKeyCode = 0x0D
    static let e: CGKeyCode = 0x0E
    static let r: CGKeyCode = 0x0F
    static let y: CGKeyCode = 0x10
    static let t: CGKeyCode = 0x11
    static let one: CGKeyCode = 0x12
    static let two: CGKeyCode = 0x13
    static let three: CGKeyCode = 0x14
    static let four: CGKeyCode = 0x15
    static let six: CGKeyCode = 0x16
    static let five: CGKeyCode = 0x17
    static let equal: CGKeyCode = 0x18
    static let nine: CGKeyCode = 0x19
    static let seven: CGKeyCode = 0x1A
    static let minus: CGKeyCode = 0x1B
    static let eight: CGKeyCode = 0x1C
    static let zero: CGKeyCode = 0x1D
    static let rightBracket: CGKeyCode = 0x1E
    static let o: CGKeyCode = 0x1F
    static let u: CGKeyCode = 0x20
    static let leftBracket: CGKeyCode = 0x21
    static let i: CGKeyCode = 0x22
    static let p: CGKeyCode = 0x23
    static let returnKey: CGKeyCode = 0x24
    static let l: CGKeyCode = 0x25
    static let j: CGKeyCode = 0x26
    static let quote: CGKeyCode = 0x27
    static let k: CGKeyCode = 0x28
    static let semicolon: CGKeyCode = 0x29
    static let backslash: CGKeyCode = 0x2A
    static let comma: CGKeyCode = 0x2B
    static let slash: CGKeyCode = 0x2C
    static let n: CGKeyCode = 0x2D
    static let m: CGKeyCode = 0x2E
    static let period: CGKeyCode = 0x2F
    static let tab: CGKeyCode = 0x30
    static let space: CGKeyCode = 0x31
    static let grave: CGKeyCode = 0x32
    /// 退格键（Mac 键盘上叫 delete）
    static let backspace: CGKeyCode = 0x33
    static let escape: CGKeyCode = 0x35
    static let rightCommand: CGKeyCode = 0x36
    static let command: CGKeyCode = 0x37
    static let shift: CGKeyCode = 0x38
    static let capsLock: CGKeyCode = 0x39
    static let option: CGKeyCode = 0x3A
    static let control: CGKeyCode = 0x3B
    static let keypadEnter: CGKeyCode = 0x4C
    static let f5: CGKeyCode = 0x60
    static let f6: CGKeyCode = 0x61
    static let f7: CGKeyCode = 0x62
    static let f3: CGKeyCode = 0x63
    static let f8: CGKeyCode = 0x64
    static let f9: CGKeyCode = 0x65
    static let f11: CGKeyCode = 0x67
    static let f10: CGKeyCode = 0x6D
    static let f12: CGKeyCode = 0x6F
    static let home: CGKeyCode = 0x73
    static let pageUp: CGKeyCode = 0x74
    /// 向前删除（Windows 键盘上的 Delete）
    static let forwardDelete: CGKeyCode = 0x75
    static let f4: CGKeyCode = 0x76
    static let end: CGKeyCode = 0x77
    static let f2: CGKeyCode = 0x78
    static let pageDown: CGKeyCode = 0x79
    static let f1: CGKeyCode = 0x7A
    static let leftArrow: CGKeyCode = 0x7B
    static let rightArrow: CGKeyCode = 0x7C
    static let downArrow: CGKeyCode = 0x7D
    static let upArrow: CGKeyCode = 0x7E

    static let letters: Set<CGKeyCode> = [
        a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    ]
    static let digits: Set<CGKeyCode> = [zero, one, two, three, four, five, six, seven, eight, nine]
    static let symbols: Set<CGKeyCode> = [
        minus, equal, leftBracket, rightBracket, backslash, semicolon, quote, comma, period, slash,
    ]
    static let arrows: Set<CGKeyCode> = [leftArrow, rightArrow, downArrow, upArrow]

    /// 这些键在真实键盘事件里带有 fn 标志，模拟时也要带上，否则有的应用不认。
    static let functionFlagKeys: Set<CGKeyCode> = [
        home, end, pageUp, pageDown, forwardDelete, leftArrow, rightArrow, downArrow, upArrow,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    ]
}

extension CGEventFlags {
    /// 只保留 ⌘ ⌥ ⌃ ⇧ 四个修饰键。
    static let modifierKeys: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
}
