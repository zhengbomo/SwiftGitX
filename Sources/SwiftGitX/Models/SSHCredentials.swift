//
//  SSHCredentials.swift
//  SwiftGitX
//
//  Created by bomo on 5/25/26.
//

import Foundation
import libgit2

/// SSH credentials for authentication
///
/// Use this struct to provide SSH key-based authentication for clone, fetch, and push operations.
public struct SSHCredentials: Sendable {
    /// The username for SSH authentication (usually "git")
    public let username: String

    /// The public key content (optional, can be nil)
    public let publicKey: String?

    /// The private key content (required)
    public let privateKey: String

    /// The passphrase for the private key (optional, can be nil for keys without passphrase)
    public let passphrase: String?

    /// Creates new SSH credentials for authentication.
    ///
    /// - Parameters:
    ///   - username: The SSH username (usually "git" for GitHub/GitLab)
    ///   - publicKey: The public key content in OpenSSH format (optional)
    ///   - privateKey: The private key content in PEM/SSH format (required)
    ///   - passphrase: The passphrase for the private key (optional)
    public init(
        username: String = "git",
        publicKey: String? = nil,
        privateKey: String,
        passphrase: String? = nil
    ) {
        self.username = username
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}
