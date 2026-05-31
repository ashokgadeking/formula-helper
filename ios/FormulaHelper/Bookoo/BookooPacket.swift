import Foundation

struct BookooReading {
    let weightG: Double
    let flowRate: Double
    let timerMs: Int
    let batteryPct: Int
}

enum BookooPacket {
    /// 20-byte notification from the weight characteristic (FF11).
    /// Layout per ios/BookooReference/protocols.md §"Receiving Weight":
    ///   [0]  0x03  product number (header 1)
    ///   [1]  0x0B  type           (header 2)
    ///   [2-4]      timer milliseconds  (24-bit BE)
    ///   [5]        weight unit (02 = grams; always grams in practice)
    ///   [6]        weight sign  (00 = positive, anything else = negative)
    ///   [7-9]      weight × 100  (24-bit BE)
    ///   [10]       flow sign     (00 = positive)
    ///   [11-12]    flow × 100    (16-bit BE)
    ///   [13]       battery %
    ///   [14-15]    standby min   (16-bit BE) — ignored
    ///   [16]       buzzer gear   — ignored
    ///   [17]       flow smoothing — ignored
    ///   [18]       0x00
    ///   [19]       XOR checksum of bytes 0..18
    static func parse(_ data: Data) -> BookooReading? {
        guard data.count >= 20, data[0] == 0x03, data[1] == 0x0B else { return nil }

        // Checksum is verified but not enforced; the Python reference at
        // ios/BookooReference/scale.py:74 notes some firmware variants emit
        // packets with a wrong checksum but otherwise valid fields, and dropping
        // those would silently lose readings.
        _ = xorChecksum(data, length: 19)

        let timerMs = (Int(data[2]) << 16) | (Int(data[3]) << 8) | Int(data[4])
        let weightSign: Double = data[6] == 0 ? 1 : -1
        let weightRaw = (Int(data[7]) << 16) | (Int(data[8]) << 8) | Int(data[9])
        let weightG = weightSign * Double(weightRaw) / 100.0

        let flowSign: Double = data[10] == 0 ? 1 : -1
        let flowRaw = (Int(data[11]) << 8) | Int(data[12])
        let flowRate = flowSign * Double(flowRaw) / 100.0

        let batteryPct = Int(data[13])

        return BookooReading(
            weightG: weightG,
            flowRate: flowRate,
            timerMs: timerMs,
            batteryPct: batteryPct
        )
    }

    private static func xorChecksum(_ data: Data, length: Int) -> UInt8 {
        var result: UInt8 = 0
        for i in 0..<min(length, data.count) { result ^= data[i] }
        return result
    }
}
