import Foundation

/// 6-byte command frames defined by the Bookoo Ultra Scale BLE protocol.
/// Sent to the command characteristic (FF12). XOR checksum is the last byte.
/// See ios/BookooReference/protocols.md for the full table.
enum BookooCommand {
    static let tare           = Data([0x03, 0x0A, 0x01, 0x00, 0x00, 0x08])
    static let startTimer     = Data([0x03, 0x0A, 0x04, 0x00, 0x00, 0x0A])
    static let stopTimer      = Data([0x03, 0x0A, 0x05, 0x00, 0x00, 0x0D])
    static let resetTimer     = Data([0x03, 0x0A, 0x06, 0x00, 0x00, 0x0C])
    static let tareAndStart   = Data([0x03, 0x0A, 0x07, 0x00, 0x00, 0x00])
}
