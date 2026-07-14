//
//  SSHCredentialCallback.swift
//  SwiftGitX
//
//  Created by bomo on 5/25/26.
//

import Foundation
import Clibgit2

/// Stores credential contexts for libgit2 callbacks
final class SSHCredentialStore: @unchecked Sendable {
    static let shared = SSHCredentialStore()

    private var storage: [String: SSHCredentials] = [:]
    private let lock = NSLock()

    func store(_ credentials: SSHCredentials, for key: String) {
        lock.lock()
        storage[key] = credentials
        lock.unlock()
    }

    func retrieve(for key: String) -> SSHCredentials? {
        lock.lock()
        let credentials = storage[key]
        lock.unlock()
        return credentials
    }

    func remove(for key: String) {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }
}

/// The credential callback function for libgit2
///
/// This callback is invoked by libgit2 when credentials are needed for SSH authentication.
func sshCredentialCallback(
    out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromUrl: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let out = out, let payload = payload else {
        return GIT_EUSER.rawValue
    }

    // Try to get the credential key from CombinedCallbackPayload
    let credentialKey: String
    let combinedPayload = Unmanaged<CombinedCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    credentialKey = combinedPayload.credentialKey

    guard let credentials = SSHCredentialStore.shared.retrieve(for: credentialKey) else {
        return GIT_EUSER.rawValue
    }
    
    if credentials.privateKey.count == 0 {
        // Create Passphrase from memory
        let result = git_credential_userpass_plaintext_new(out, credentials.username, credentials.passphrase)
        return result
    } else {
        // Create SSH key from memory
        let result = git_cred_ssh_key_memory_new(
            out,
            credentials.username,
            credentials.publicKey,
            credentials.privateKey,
            credentials.passphrase
        )
        return result
    }
}

/// Creates a persistent pointer to a String for use as callback payload
final class CredentialKeyHolder {
    let key: String

    init(_ key: String) {
        self.key = key
    }
}

/// Combined payload for both credentials and transfer progress
final class CombinedCallbackPayload {
    let credentialKey: String
    var transferProgressHandler: TransferProgressHandler?

    init(credentialKey: String, transferProgressHandler: TransferProgressHandler? = nil) {
        self.credentialKey = credentialKey
        self.transferProgressHandler = transferProgressHandler
    }
}

/// Generates a unique key and returns a pointer holder for use as callback payload
func createCredentialPayload(for credentials: SSHCredentials) -> (key: String, payload: UnsafeMutableRawPointer) {
    let key = UUID().uuidString
    SSHCredentialStore.shared.store(credentials, for: key)

    let holder = CredentialKeyHolder(key)
    let pointer = Unmanaged.passRetained(holder).toOpaque()

    return (key, pointer)
}

/// Creates a combined payload for credentials and transfer progress handler
func createCombinedPayload(
    for credentials: SSHCredentials,
    transferProgressHandler: TransferProgressHandler? = nil
) -> (key: String, payload: UnsafeMutableRawPointer) {
    let key = UUID().uuidString
    SSHCredentialStore.shared.store(credentials, for: key)

    let combined = CombinedCallbackPayload(credentialKey: key, transferProgressHandler: transferProgressHandler)
    let pointer = Unmanaged.passRetained(combined).toOpaque()

    return (key, pointer)
}

/// Releases a combined payload created by createCombinedPayload
func releaseCombinedPayload(_ payload: UnsafeMutableRawPointer, key: String) {
    SSHCredentialStore.shared.remove(for: key)
    Unmanaged<CombinedCallbackPayload>.fromOpaque(payload).release()
}

/// Releases a credential payload created by createCredentialPayload
func releaseCredentialPayload(_ payload: UnsafeMutableRawPointer, key: String) {
    SSHCredentialStore.shared.remove(for: key)
    Unmanaged<CredentialKeyHolder>.fromOpaque(payload).release()
}

/// The certificate check callback function for libgit2
///
/// This callback is invoked by libgit2 to verify SSL/TLS certificates during SSH/HTTPS operations.
/// By default, it accepts all certificates (returns 0).
///
/// - Parameters:
///   - cert: Pointer to the certificate information
///   - valid: Whether the certificate is valid according to libgit2's checks
///   - host: The hostname being connected to
///   - payload: User-provided payload (unused in this implementation)
///
/// - Returns: 0 to accept the certificate, non-zero to reject
let certificateCheckCallback: git_transport_certificate_check_cb = { cert, valid, host, payload in
    // For now, accept all certificates
    // In production, you might want to:
    // 1. Check the 'valid' parameter
    // 2. Verify the certificate against known hosts
    // 3. Prompt the user for unknown certificates
    return 0
}
