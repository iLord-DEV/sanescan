import CryptoKit
import Foundation

// Verify against the public key embedded in the app, independently of Sparkle's
// signing tool. A wrong CI signing key must never produce a published release.
guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let publicKey = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Expected archive path, Ed25519 signature and public key")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("The update archive does not match the app's public signing key.\n", stderr)
    exit(1)
}
print("Ed25519 archive signature verified")
