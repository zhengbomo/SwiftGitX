//
//  Repository+fetch.swift
//  SwiftGitX
//
//  Created by İbrahim Çetin on 23.11.2025.
//

import Foundation
import Clibgit2

extension Repository {
    /// Fetch the objects and refs from the other repository.
    ///
    /// - Parameter remote: The remote to fetch the changes from.
    ///
    /// This method uses the default refspecs to fetch the changes from the remote.
    ///
    /// If the remote is not specified, the upstream of the current branch is used
    /// and if the upstream branch is not found, the `origin` remote is used.
    public nonisolated func fetch(remote: Remote? = nil) async throws(SwiftGitXError) {
        guard let remote = remote ?? (try? branch.current.remote) ?? self.remote["origin"] else {
            throw SwiftGitXError(code: .notFound, category: .reference, message: "Remote not found")
        }

        // Lookup the remote
        let remotePointer = try ReferenceFactory.lookupRemotePointer(name: remote.name, repositoryPointer: pointer)
        defer { git_remote_free(remotePointer) }

        // Perform the fetch operation
        try git(operation: .fetch) {
            git_remote_fetch(remotePointer, nil, nil, nil)
        }
    }

    /// Fetch the objects and refs from the other repository with SSH credentials.
    ///
    /// Use this method when fetching from SSH URLs that require SSH key authentication.
    ///
    /// - Parameters:
    ///   - remote: The remote to fetch the changes from.
    ///   - credentials: The SSH credentials for authentication.
    ///
    /// This method uses the default refspecs to fetch the changes from the remote.
    ///
    /// If the remote is not specified, the upstream of the current branch is used
    /// and if the upstream branch is not found, the `origin` remote is used.
    public nonisolated func fetch(
        remote: Remote? = nil,
        credentials: SSHCredentials
    ) async throws(SwiftGitXError) {
        guard let remote = remote ?? (try? branch.current.remote) ?? self.remote["origin"] else {
            throw SwiftGitXError(code: .notFound, category: .reference, message: "Remote not found")
        }

        // Create credential payload
        let (credentialKey, credentialPayload) = createCredentialPayload(for: credentials)
        defer { releaseCredentialPayload(credentialPayload, key: credentialKey) }

        // Set up fetch options with credentials callback
        var fetchOpts = git_fetch_options()
        fetchOpts.callbacks.credentials = sshCredentialCallback
        fetchOpts.callbacks.payload = UnsafeMutableRawPointer(mutating: credentialPayload)

        // Lookup the remote
        let remotePointer = try ReferenceFactory.lookupRemotePointer(name: remote.name, repositoryPointer: pointer)
        defer { git_remote_free(remotePointer) }

        // Perform the fetch operation
        try git(operation: .fetch) {
            git_remote_fetch(remotePointer, nil, &fetchOpts, nil)
        }
    }

    // TODO: Implement pull
}
