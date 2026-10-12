import Foundation
import CryptoKit
let encoded = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: encoded, encoding: .utf8), let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
    fatalError("Invalid update signing key format")
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let expected = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard key.publicKey.rawRepresentation.base64EncodedString() == expected else { fatalError("Update signing key does not match the application's trusted public key") }
print("Update signing key matches application public key.")
