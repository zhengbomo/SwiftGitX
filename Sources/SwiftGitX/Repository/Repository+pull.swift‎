//
//  Repository+pull.swift
//  SwiftGitX
//
//  Created by dunkbing
//

import Clibgit2

extension Repository {
    /// Pull changes from the remote repository.
    ///
    /// - Parameter remote: The remote to pull the changes from.
    ///
    /// This method fetches changes from the remote and merges them into the current branch.
    /// It supports fast-forward merges and normal merges.
    ///
    /// If the remote is not specified, the upstream of the current branch is used
    /// and if the upstream branch is not found, the `origin` remote is used.
    ///
    /// - Throws: `SwiftGitXError` if the pull operation fails or if there are conflicts.
    ///
    /// ### Example
    /// ```swift
    /// // Pull from the default remote
    /// try await repository.pull()
    ///
    /// // Pull from a specific remote
    /// let remote = repository.remote["origin"]!
    /// try await repository.pull(remote: remote)
    /// ```
    public nonisolated func pull(remote: Remote? = nil) async throws(SwiftGitXError) {
        // Get the current branch
        let currentBranch = try branch.current

        // Get the remote
        guard let remote = remote ?? currentBranch.remote ?? self.remote["origin"] else {
            throw SwiftGitXError(code: .notFound, operation: .pull, category: .reference, message: "Remote not found")
        }

        // Get the upstream branch name
        guard let upstream = currentBranch.upstream else {
            throw SwiftGitXError(
                code: .notFound, operation: .pull, category: .reference,
                message: "No upstream branch configured for '\(currentBranch.name)'"
            )
        }

        // Fetch from remote first
        try await fetch(remote: remote)

        // Get the remote branch after fetch
        let remoteBranch = try branch.get(named: upstream.name, type: .remote)

        // Get the commit to merge
        guard let remoteCommit = remoteBranch.target as? Commit else {
            throw SwiftGitXError(
                code: .error, operation: .pull, category: .reference,
                message: "Remote branch does not point to a commit"
            )
        }

        // Perform merge analysis
        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)

        var remoteOID = remoteCommit.id.raw
        var annotatedCommit: OpaquePointer?

        try git(operation: .pull) {
            git_annotated_commit_lookup(&annotatedCommit, pointer, &remoteOID)
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        var annotatedCommits: [OpaquePointer?] = [annotatedCommit]

        try git(operation: .pull) {
            annotatedCommits.withUnsafeMutableBufferPointer { buffer in
                git_merge_analysis(&analysis, &preference, pointer, buffer.baseAddress, 1)
            }
        }

        // Check if we're already up to date
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            // Already up to date, nothing to do
            return
        }

        // Check if we can fast-forward
        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            // Fast-forward merge: simply reset HEAD to the remote commit
            try reset(to: remoteCommit, mode: .hard)
            return
        }

        // Normal merge required
        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            try performMerge(
                annotatedCommit: annotatedCommit!,
                remoteBranch: remoteBranch,
                remoteCommit: remoteCommit
            )
            return
        }

        throw SwiftGitXError(
            code: .error, operation: .pull, category: .merge,
            message: "Merge analysis returned unexpected result"
        )
    }

    // MARK: - Private Helpers

    /// Performs a normal merge with the given annotated commit.
    private func performMerge(
        annotatedCommit: OpaquePointer,
        remoteBranch: Branch,
        remoteCommit: Commit
    ) throws(SwiftGitXError) {
        // Initialize merge options
        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))

        // Initialize checkout options
        var checkoutOptions = git_checkout_options()
        git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        // Perform the merge
        var annotatedCommits: [OpaquePointer?] = [annotatedCommit]

        try git(operation: .merge) {
            annotatedCommits.withUnsafeMutableBufferPointer { buffer in
                git_merge(pointer, buffer.baseAddress, 1, &mergeOptions, &checkoutOptions)
            }
        }

        // Check for conflicts
        let index = try git(operation: .merge) {
            var indexPointer: OpaquePointer?
            let status = git_repository_index(&indexPointer, pointer)
            return (indexPointer, status)
        }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) == 1 {
            // Clean up merge state
            git_repository_state_cleanup(pointer)

            throw SwiftGitXError(
                code: .conflict, operation: .pull, category: .merge,
                message: "Merge conflicts detected. Please resolve conflicts manually."
            )
        }

        // Create merge commit
        try createMergeCommit(remoteBranch: remoteBranch, remoteCommit: remoteCommit)

        // Clean up merge state
        git_repository_state_cleanup(pointer)
    }

    /// Creates a merge commit after a successful merge.
    private func createMergeCommit(remoteBranch: Branch, remoteCommit: Commit) throws(SwiftGitXError) {
        // Get the index
        let index = try git(operation: .merge) {
            var indexPointer: OpaquePointer?
            let status = git_repository_index(&indexPointer, pointer)
            return (indexPointer, status)
        }
        defer { git_index_free(index) }

        // Write the index as a tree
        var treeOID = git_oid()
        try git(operation: .merge) {
            git_index_write_tree(&treeOID, index)
        }

        // Get the tree
        let tree = try git(operation: .merge) {
            var treePointer: OpaquePointer?
            let status = git_tree_lookup(&treePointer, pointer, &treeOID)
            return (treePointer, status)
        }
        defer { git_tree_free(tree) }

        // Get HEAD commit
        let headCommit = try HEAD.target as! Commit

        // Get signature
        var signature: UnsafeMutablePointer<git_signature>?
        try git(operation: .merge) {
            git_signature_default(&signature, pointer)
        }
        defer { git_signature_free(signature) }

        // Create merge commit message
        let message = "Merge branch '\(remoteBranch.displayName)'"

        // Get parent commit pointers
        let headCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: headCommit.id.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(headCommitPointer) }

        let remoteCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: remoteCommit.id.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(remoteCommitPointer) }

        // Create the merge commit
        var commitOID = git_oid()
        var parents: [OpaquePointer?] = [headCommitPointer, remoteCommitPointer]

        try git(operation: .merge) {
            parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOID,
                    pointer,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    message,
                    tree,
                    2,
                    buffer.baseAddress
                )
            }
        }
    }
}

// MARK: - Branch Display Name Extension

extension Branch {
    /// Returns a display-friendly name for the branch.
    var displayName: String {
        if type == .remote {
            // Remove remote prefix (e.g., "origin/main" -> "main")
            let remoteName = remote?.name ?? "origin"
            return name.replacingOccurrences(of: "\(remoteName)/", with: "")
        }
        return name
    }
}
