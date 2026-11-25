import CryptoKit
import Foundation

// A host's emblem pattern: a left-to-right mirrored 5×5 grid lit from the MD5 of its ssh alias.
enum HostSignature {
    static let side = 5
    private static let drawnColumns = 3

    static func cells(of host: SSHHostID) -> [Bool] {
        let digest = Array(Insecure.MD5.hash(data: Data(host.alias.utf8)))
        func bit(_ index: Int) -> Bool { digest[index / 8] >> (7 - index % 8) & 1 == 1 }
        return (0..<side * side).map { cell in
            let row = cell / side
            let column = cell % side
            let drawn = column < drawnColumns ? column : side - 1 - column
            return bit(row * drawnColumns + drawn)
        }
    }
}
