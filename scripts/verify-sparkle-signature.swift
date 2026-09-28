#!/usr/bin/env swift
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Sparkle signature invalid: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: verify-sparkle-signature.swift <archive> <base64-signature> <base64-public-key>")
}

do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64,
          let keyData = Data(base64Encoded: CommandLine.arguments[3]), keyData.count == 32 else {
        fail("signature or public key has an invalid encoding")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fail("archive bytes do not match the Ed25519 signature")
    }
    print("Sparkle Ed25519 signature verified.")
} catch {
    fail(error.localizedDescription)
}
