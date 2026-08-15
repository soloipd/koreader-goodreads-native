# Security policy

## Supported versions

Only the latest tagged release receives security fixes.

## Security model

This plugin deliberately loads a small Java agent into the Kindle framework.
That is a privileged operation and should be treated like any other jailbreak
extension:

- install releases only from a source you trust;
- verify the published SHA-256 checksum;
- keep SSH key-only and disabled when it is not needed;
- do not add Amazon, Goodreads, or Readwise credentials to plugin files;
- do not expose the Kindle SSH service to an untrusted network.

The plugin accepts only a ten-character Amazon ASIN beginning with `B` and an
integer percentage from 1 through 100. It does not accept or persist account
credentials. Agents write only sanitized success/failure results to `/tmp`.
Annotation text is carried in a size-bounded, mode-0600 transient `/tmp`
payload, removed after every attempt, and then handled by the Kindle's native
annotation store. Persistent plugin annotation state contains coordinate keys
only; logs never accept annotation text.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting feature when available. Please do
not open a public issue containing credentials, device identifiers, session
tokens, or exploit details that would endanger jailbreak users.
