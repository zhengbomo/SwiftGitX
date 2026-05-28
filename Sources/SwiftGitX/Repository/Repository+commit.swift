//
//  Repository+commit.swift
//  SwiftGitX
//
//  Created by İbrahim Çetin on 23.11.2025.
//

import Clibgit2

extension Repository {
    /// Check if the repository is currently in a merge state.
    ///
    /// - Returns: `true` if the repository is in a merge state, `false` otherwise.
    ///
    /// This can be used to determine whether `commitMerge()` should be called
    /// instead of the regular `commit()` method.
    ///
    /// ### Example
    /// ```swift
    /// if repository.isInMergeState {
    ///     try repository.commitMerge()
    /// } else {
    ///     try repository.commit(message: "Regular commit")
    /// }
    /// ```
    public var isInMergeState: Bool {
        let state = git_repository_state(pointer)
        return state == GIT_REPOSITORY_STATE_MERGE.rawValue
    }

    /// Create a new commit containing the current contents of the index.
    ///
    /// - Parameters:
    ///   - message: The commit message.
    ///   - options: The options to use when creating the commit.
    ///
    /// - Returns: The created commit.
    ///
    /// This method uses the default author and committer information.
    @discardableResult
    public func commit(message: String, options: CommitOptions = .default) throws(SwiftGitXError) -> Commit {
        // Create a new commit from the index
        var oid = git_oid()
        var gitOptions = options.gitCommitCreateOptions

        try git(operation: .commit) {
            git_commit_create_from_stage(
                &oid,
                pointer,
                message,
                &gitOptions
            )
        }

        // Lookup the resulting commit
        return try ObjectFactory.lookupCommit(oid: oid, repositoryPointer: pointer)
    }

    /// Complete a merge by creating a merge commit after conflicts have been resolved.
    ///
    /// - Parameter message: The commit message. If nil, a default merge message will be generated.
    ///
    /// - Returns: The created merge commit.
    ///
    /// This method should be called after resolving merge conflicts. It will:
    /// 1. Check that the repository is in a MERGE state
    /// 2. Verify that all conflicts have been resolved
    /// 3. Create a merge commit with two parents (HEAD and MERGE_HEAD)
    /// 4. Clean up the merge state
    ///
    /// - Throws: `SwiftGitXError` if:
    ///   - The repository is not in a merge state
    ///   - There are unresolved conflicts
    ///   - The commit creation fails
    ///
    /// ### Example
    /// ```swift
    /// // After resolving conflicts manually
    /// try repository.add(path: "conflicted-file.txt")
    /// try repository.commitMerge(message: "Merge branch 'feature' with conflicts resolved")
    /// ```
    @discardableResult
    public func commitMerge(message: String? = nil) throws(SwiftGitXError) -> Commit {
        // Check if repository is in MERGE state
        let state = git_repository_state(pointer)
        guard state == GIT_REPOSITORY_STATE_MERGE.rawValue else {
            throw SwiftGitXError(
                code: .error,
                operation: .commit,
                category: .merge,
                message: "Repository is not in a merge state"
            )
        }

        // Get the index and check for conflicts
        let index = try git(operation: .commit) {
            var indexPointer: OpaquePointer?
            let status = git_repository_index(&indexPointer, pointer)
            return (indexPointer, status)
        }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) == 1 {
            throw SwiftGitXError(
                code: .conflict,
                operation: .commit,
                category: .merge,
                message: "Cannot commit merge: unresolved conflicts remain"
            )
        }

        // Write the index as a tree
        var treeOID = git_oid()
        try git(operation: .commit) {
            git_index_write_tree(&treeOID, index)
        }

        // Get the tree
        let tree = try git(operation: .commit) {
            var treePointer: OpaquePointer?
            let status = git_tree_lookup(&treePointer, pointer, &treeOID)
            return (treePointer, status)
        }
        defer { git_tree_free(tree) }

        // Get HEAD commit (first parent)
        let headCommit = try HEAD.target as! Commit

        // Get MERGE_HEAD (second parent)
        var mergeHeadOID = git_oid()
        try git(operation: .commit) {
            git_repository_mergehead_foreach(pointer, { oid, payload in
                guard let oid = oid else { return 0 }
                payload?.assumingMemoryBound(to: git_oid.self).pointee = oid.pointee
                return 0
            }, &mergeHeadOID)
        }

        let mergeHeadCommit = try ObjectFactory.lookupCommit(oid: mergeHeadOID, repositoryPointer: pointer)

        // Get signature
        var signature: UnsafeMutablePointer<git_signature>?
        try git(operation: .commit) {
            git_signature_default(&signature, pointer)
        }
        defer { git_signature_free(signature) }

        // Generate default message if not provided
        let commitMessage: String
        if let message = message {
            commitMessage = message
        } else {
            // Try to read MERGE_MSG file for default message
            let mergeMsg: String? = try? git(operation: .commit) {
                var buf = git_buf()
                let status = git_repository_message(&buf, pointer)
                defer { git_buf_dispose(&buf) }

                if status == 0, let ptr = buf.ptr {
                    let msg = String(cString: ptr)
                    return (msg, 0)
                }
                return (nil, status)
            }

            commitMessage = mergeMsg ?? "Merge commit"
        }

        // Get parent commit pointers
        let headCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: headCommit.id.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(headCommitPointer) }

        let mergeHeadCommitPointer = try ObjectFactory.lookupObjectPointer(
            oid: mergeHeadCommit.id.raw,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(mergeHeadCommitPointer) }

        // Create the merge commit
        var commitOID = git_oid()
        var parents: [OpaquePointer?] = [headCommitPointer, mergeHeadCommitPointer]

        try git(operation: .commit) {
            parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOID,
                    pointer,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    commitMessage,
                    tree,
                    2,
                    buffer.baseAddress
                )
            }
        }

        // Clean up merge state
        git_repository_state_cleanup(pointer)

        // Lookup and return the resulting commit
        return try ObjectFactory.lookupCommit(oid: commitOID, repositoryPointer: pointer)
    }
}
