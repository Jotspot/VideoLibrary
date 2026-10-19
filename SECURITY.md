# Security Policy

VideoLibrary stores sign-in cookies and tokens encrypted (AES-GCM, key in the macOS Keychain) and runs local servers only for the OAuth callback (loopback) and optional Wi-Fi sharing (token-protected).

If you find a security problem, please **don't open a public issue**. Report it privately through GitHub's [private vulnerability reporting](https://github.com/Jotspot/VideoLibrary/security/advisories/new) instead. Please include steps to reproduce and the app and macOS versions.

Only the latest release receives fixes.
