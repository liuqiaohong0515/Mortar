# Mortar

Mortar is a native macOS application for Subversion. It keeps a library of repositories and working copies on this Mac, and it ships Subversion 1.15 (`svn`, `svnadmin`, `svnlook`, `svnversion`, and `svnmucc`), so everyday work does not depend on a copy of `svn` installed elsewhere.

The main window is a browser. Pick a working copy or a repository in the source list, then walk its folders. Columns show revision, author, date, size, kind, properties, lock, and depth. Filters narrow the list to changed, modified, conflicted, missing, unversioned, switched, locked, or newer items, and to changes from today, this week, or this month. A search field sits beside those filters. Ignored files, externals, and repository status can be shown or hidden. The inspector shows Subversion info and properties for the selection; properties can be set, deleted, or restored to the base value.

## Changing a working copy

Checkout creates a working copy at a chosen revision and depth. Update can go to the latest revision or to one you name, with or without externals. Commit lists the paths that will be sent, lets you leave some out, and can run a script before and after the commit. Revert, add, delete, and ignore apply to the selection. A working copy can be switched to another URL, relocated, cleaned up, or repaired. Files can be locked and unlocked. Conflicts can be resolved in Mortar or handed to an external merge tool.

Merge takes a source URL and a revision range, with options for whitespace, line endings, ancestry, a dry run, and recording the merge without changing files. Branches and tags are copies made in the repository. Import sends local files in, export writes a tree out, and a patch saves the current diff. Shelve sets local changes aside so they can be restored later. Externals on the selection can be edited. Drop a working copy or a local repository onto the window to add it to the library. A working copy on a network volume asks for confirmation before it is added.

## Comparing and history

Compare shows a file against its base, HEAD, or another revision. Text comparisons can fold whitespace and line endings, show blame, and apply a single change back onto the working copy. Image files are compared as images. The same two sides can be opened in an external diff tool. Hold Option when comparing or resolving to use that external tool.

The log lists recent revisions for the selection. The timeline groups that history and can follow a change to its ancestor. The transcript records the Subversion commands Mortar runs, and a note can be attached to an entry. Subversion’s own help text can be opened from the Help menu.

## Library, credentials, and preferences

Repositories can be a local path or an `http`, `https`, or `svn` URL. Passwords are stored in the Keychain, per repository and username. Hosts you choose to trust are remembered, and can be removed in Settings. SSH can use a port, an identity file, and extra environment variables. HTTP can use a proxy and a client certificate. Ignore rules, auto-props, and commit times are passed through to `svn`. Mortar can share the system Subversion and SSH configuration, or keep its own.

The interface follows the system language, or a language chosen in Settings: English, Simplified and Traditional Chinese, Japanese, Korean, German, French, Spanish, Italian, Portuguese, Dutch, Swedish, Danish, Norwegian, and Finnish. Double-click can open an item, compare it, or show it in Quick Look. Checkout, update, commit, import, and export can post a notification. The whole library, including preferences, can be exported and imported. An export can include saved passwords when you give it a passphrase.

Mortar waits to quit while a Subversion command is still running.

## Requirements

macOS 26 or later. Open `Mortar.xcodeproj` and run the Mortar target.

## License

The application source is under the MIT License, including commercial use. See `LICENSE`.

The Subversion binaries in `Vendor/svn` and `Mortar/SVN.bundle` are third-party and keep their own licenses. See `NOTICE`.
