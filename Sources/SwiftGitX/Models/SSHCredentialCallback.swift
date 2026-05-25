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

    // The payload is a pointer to a stored String key
    let keyPtr = payload.assumingMemoryBound(to: String.self)
    let key = keyPtr.pointee

    guard let credentials = SSHCredentialStore.shared.retrieve(for: key) else {
        return GIT_EUSER.rawValue
    }

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

/// Creates a persistent pointer to a String for use as callback payload
final class CredentialKeyHolder {
    let key: String

    init(_ key: String) {
        self.key = key
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

/// Releases a credential payload created by createCredentialPayload
func releaseCredentialPayload(_ payload: UnsafeMutableRawPointer, key: String) {
    SSHCredentialStore.shared.remove(for: key)
    Unmanaged<CredentialKeyHolder>.fromOpaque(payload).release()
}
