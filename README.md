# Mortar

Mortar is a native macOS application for Subversion. It keeps a library of repositories and working copies, and ships its own Subversion 1.15 tools, so everyday work does not depend on a copy of `svn` installed elsewhere on the Mac.

Open a working copy or a repository and browse it like a folder. From the same window you can check out, update, commit, revert, switch, merge, branch, and tag. Import and export move files in and out of the repository, and a local patch can be saved as a diff. Files can be locked, conflicts resolved, and a working copy cleaned up or repaired.

The compare view shows a text or image change against another revision, with blame when you want the last author of each line. Whitespace and line endings can be folded out of the comparison, and the same two sides can be handed to an external diff or merge tool. The log lists revisions, the timeline groups recent history, and the transcript records the Subversion commands Mortar runs.

Passwords are stored in the Keychain. SSH identity, HTTP proxy, ignore rules, and auto-props are applied to those commands. The library itself can be exported and imported. The interface follows the system language, including English, Chinese, Japanese, Korean, and several European languages.

Requires macOS 26 or later. Open `Mortar.xcodeproj` and run the Mortar target.

Source code is under the MIT License, including commercial use. The Subversion binaries in `Vendor/svn` and `Mortar/SVN.bundle` keep their own licenses; see `NOTICE`.
