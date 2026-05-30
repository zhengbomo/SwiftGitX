//
//  Repository+pull.swift
//  SwiftGitX
//
//  Created by dunkbing
//

import Clibgit2

extension Repository {
    /// Check if there would be conflicts when merging remote changes.
    ///
    /// - Parameters:
    ///   - remote: The remote to check against. If nil, uses the upstream of the current branch or "origin".
    ///   - shouldFetch: Whether to fetch from remote before checking. Default is true.
    ///
    /// - Returns: A tuple containing:
    ///   - hasConflicts: Whether conflicts would occur
    ///   - conflictFiles: Array of file paths that would have conflicts (empty if no conflicts)
    ///   - localCommitId: The current HEAD commit ID
    ///   - remoteCommitId: The remote branch's latest commit ID
    ///
    /// - Throws: `SwiftGitXError` if the operation fails.
    ///
    /// ### Example
    /// ```swift
    /// let result = try await repository.checkMergeConflicts()
    /// if result.hasConflicts {
    ///     print("冲突文件: \(result.conflictFiles)")
    /// } else {
    ///     print("无冲突，可以安全合并")
    /// }
    /// ```
    public nonisolated func checkMergeConflicts(
        remote: Remote? = nil,
        shouldFetch: Bool = true
    ) async throws(SwiftGitXError) -> (hasConflicts: Bool, conflictFiles: [String], localCommitId: String, remoteCommitId: String) {
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

        // Fetch from remote first if needed
        if shouldFetch {
            try await fetch(remote: remote)
        }

        // Get the remote branch after fetch
        let remoteBranch = try branch.get(named: upstream.name, type: .remote)

        // Get the remote commit
        guard let remoteCommit = remoteBranch.target as? Commit else {
            throw SwiftGitXError(
                code: .error, operation: .pull, category: .reference,
                message: "Remote branch does not point to a commit"
            )
        }

        // Get HEAD commit
        let headCommit = try HEAD.target as! Commit

        let localCommitId = headCommit.id.hex
        let remoteCommitId = remoteCommit.id.hex

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

        // Check if we're already up to date or can fast-forward
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return (false, [], localCommitId, remoteCommitId)
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            return (false, [], localCommitId, remoteCommitId)
        }

        // Normal merge required - check for conflicts in memory
        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            // Find merge base (common ancestor)
            var mergeBaseOID = git_oid()
            try git(operation: .merge) {
                var localOID = headCommit.id.raw
                var remoteOID = remoteCommit.id.raw
                git_merge_base(&mergeBaseOID, pointer, &localOID, &remoteOID)
            }

            // Get ancestor tree
            let ancestorTree = try git(operation: .merge) {
                var treePointer: OpaquePointer?
                var ancestorCommitPointer: OpaquePointer?
                var ancestorOID = mergeBaseOID
                var status = git_commit_lookup(&ancestorCommitPointer, pointer, &ancestorOID)
                if status == 0 {
                    status = git_commit_tree(&treePointer, ancestorCommitPointer)
                    git_commit_free(ancestorCommitPointer)
                }
                return (treePointer, status)
            }
            defer { git_tree_free(ancestorTree) }

            // Get local and remote trees
            let localTree = try git(operation: .merge) {
                var treePointer: OpaquePointer?
                var localOID = headCommit.id.raw
                var localCommitPointer: OpaquePointer?
                var status = git_commit_lookup(&localCommitPointer, pointer, &localOID)
                if status == 0 {
                    status = git_commit_tree(&treePointer, localCommitPointer)
                    git_commit_free(localCommitPointer)
                }
                return (treePointer, status)
            }
            defer { git_tree_free(localTree) }

            let remoteTree = try git(operation: .merge) {
                var treePointer: OpaquePointer?
                var remoteOID = remoteCommit.id.raw
                var remoteCommitPointer: OpaquePointer?
                var status = git_commit_lookup(&remoteCommitPointer, pointer, &remoteOID)
                if status == 0 {
                    status = git_commit_tree(&treePointer, remoteCommitPointer)
                    git_commit_free(remoteCommitPointer)
                }
                return (treePointer, status)
            }
            defer { git_tree_free(remoteTree) }

            // Merge trees in memory with ancestor (three-way merge)
            var mergeOptions = git_merge_options()
            git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))

            let index = try git(operation: .merge) {
                var indexPointer: OpaquePointer?
                let status = git_merge_trees(&indexPointer, pointer, ancestorTree, localTree, remoteTree, &mergeOptions)
                return (indexPointer, status)
            }
            defer { git_index_free(index) }

            // Check for conflicts
            if git_index_has_conflicts(index) == 1 {
                var conflictFiles: [String] = []

                // Iterate through conflicts
                var conflictIterator: OpaquePointer?
                git_index_conflict_iterator_new(&conflictIterator, index)
                defer { git_index_conflict_iterator_free(conflictIterator) }

                var ancestor: UnsafePointer<git_index_entry>?
                var our: UnsafePointer<git_index_entry>?
                var their: UnsafePointer<git_index_entry>?

                while git_index_conflict_next(&ancestor, &our, &their, conflictIterator) == 0 {
                    if let path = our?.pointee.path {
                        conflictFiles.append(String(cString: path))
                    } else if let path = their?.pointee.path {
                        conflictFiles.append(String(cString: path))
                    } else if let path = ancestor?.pointee.path {
                        conflictFiles.append(String(cString: path))
                    }
                }

                return (true, conflictFiles, localCommitId, remoteCommitId)
            } else {
                return (false, [], localCommitId, remoteCommitId)
            }
        }

        throw SwiftGitXError(
            code: .error, operation: .pull, category: .merge,
            message: "Merge analysis returned unexpected result"
        )
    }

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
        try await pullInternal(remote: remote, credentials: nil)
    }

    /// Pull changes from the remote repository with SSH credentials.
    ///
    /// Use this method when pulling from SSH URLs that require SSH key authentication.
    ///
    /// - Parameters:
    ///   - remote: The remote to pull the changes from.
    ///   - credentials: The SSH credentials for authentication.
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
    /// // Pull with SSH credentials
    /// let credentials = SSHCredentials(
    ///     username: "git",
    ///     privateKey: privateKeyContent,
    ///     passphrase: "mypassphrase"
    /// )
    /// try await repository.pull(credentials: credentials)
    ///
    /// // Pull from a specific remote with credentials
    /// let remote = repository.remote["origin"]!
    /// try await repository.pull(remote: remote, credentials: credentials)
    /// ```
    public nonisolated func pull(
        remote: Remote? = nil,
        credentials: SSHCredentials
    ) async throws(SwiftGitXError) {
        try await pullInternal(remote: remote, credentials: credentials)
    }

    /// Merge changes from the remote branch without fetching.
    ///
    /// - Parameter remote: The remote to merge from.
    ///
    /// This method merges the remote branch into the current branch without fetching first.
    /// Use this when you've already fetched and want to merge the changes.
    /// It supports fast-forward merges and normal merges.
    ///
    /// If the remote is not specified, the upstream of the current branch is used
    /// and if the upstream branch is not found, the `origin` remote is used.
    ///
    /// - Throws: `SwiftGitXError` if the merge operation fails or if there are conflicts.
    ///
    /// ### Example
    /// ```swift
    /// // Fetch first
    /// try await repository.fetch()
    ///
    /// // Then merge without fetching again
    /// try await repository.merge()
    ///
    /// // Merge from a specific remote
    /// let remote = repository.remote["origin"]!
    /// try await repository.merge(remote: remote)
    /// ```
    public nonisolated func merge(remote: Remote? = nil) async throws(SwiftGitXError) {
        try await mergeInternal(remote: remote)
    }

    /// Internal implementation of pull that handles both authenticated and non-authenticated cases.
    private nonisolated func pullInternal(
        remote: Remote? = nil,
        credentials: SSHCredentials?
    ) async throws(SwiftGitXError) {
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
        if let credentials = credentials {
            try await fetch(remote: remote, credentials: credentials)
        } else {
            try await fetch(remote: remote)
        }

        // Perform the merge
        try await mergeInternal(remote: remote)
    }

    /// Internal implementation of merge that performs the actual merge operation.
    private nonisolated func mergeInternal(
        remote: Remote? = nil
    ) async throws(SwiftGitXError) {
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

        // Get the remote branch
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
            // Don't clean up merge state - leave it so user can resolve conflicts and call commitMerge()
            // The merge state will be cleaned up when commitMerge() is called after resolving conflicts

            throw SwiftGitXError(
                code: .conflict, operation: .pull, category: .merge,
                message: "Merge conflicts detected. Please resolve conflicts manually and call commitMerge()."
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
