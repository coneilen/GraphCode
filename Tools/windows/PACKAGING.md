# Windows release packaging

`package.ps1` produces a self-contained `GraphCode-<version>-windows-x86_64`
directory and ZIP. The bundle contains the GraphCode shell, `graphcoded`,
`graphcode`, `zmx`, Winghostty host assets, Swift runtime DLLs, pinned provider
metadata, `LICENSE`, and `THIRD-PARTY-NOTICES.txt`.

```powershell
pwsh Tools/windows/package.ps1 -Command Build `
  -InputDirectory .build/windows/release `
  -Version 1.0.0
pwsh Tools/windows/package.ps1 -Command Verify `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64.zip
pwsh Tools/windows/package.ps1 -Command Install `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64
```

The ZIP contains one top-level `GraphCode` directory. Installation verifies the
complete manifest and provider provenance before copying anything, then stages
and swaps atomically. The scheduled task is created and run; the exact installed
daemon endpoint must become reachable or the previous installation is restored.
The daemon's actual `%USERPROFILE%\.graphcode` data directory is preserved by
uninstall unless `-RemoveUserData` is explicitly requested.

Unsigned artifacts are explicitly marked `UNSIGNED (development artifact; not
code signed)` in `metadata.json` and `SIGNING.txt`. Their checksums detect
corruption, not publisher authenticity. They remain accepted for development
unless `-TrustedSignerThumbprint` is supplied.

## Failed installation and recovery

Install and upgrade track which transaction steps actually completed. A failed
daemon stop, locked installation, or failed move to backup never authorizes
deleting the existing installation. Same-volume directory renames prevent the
partial recursive moves that PowerShell can perform on locked trees.
Only a newly promoted payload is removed
during rollback. Staging and shortcut-snapshot failures also clean up their
temporary directories without changing the installed product.

If rollback itself fails, the command reports both the initiating failure and
the recovery errors, rather than replacing one with the other. An unrestored
previous installation is retained in the reported `.GraphCode-rollback-<id>`
directory alongside the installation root. A failed shortcut restoration keeps
its `.GraphCode-shortcut-<id>` snapshot and reports that path too. Do not delete
these recovery directories until the previous installation/integration has been
restored. The previous daemon is restarted only when its payload is back at the
installation root; an incomplete rollback is never reported as a successful
installation.

`Packaging.Rollback.Tests.ps1` covers pre-swap failures, failed promotion,
post-swap rollback, secondary recovery failures, fresh/portable installs, and a
native Windows file-sharing lock. It isolates daemon and shortcut operations;
the real-product packaging gate separately exercises scheduled-daemon
install/upgrade/rollback/uninstall.

## Signed package integrity

Signing is opt-in: `-SignCertificate <thumbprint>` requires a trusted code-signing
certificate with its private key and the Windows SDK's `signtool.exe` (or
`-SignToolPath`). Executables are signed with SHA-256, then their final hashes
are recorded in the manifest and provider provenance. A SHA-256 `package.cat`
catalog covers the payload, runtime DLLs, licenses, metadata, manifest, and
checksum list. The catalog is signed by the same publisher. Third-party DLLs
retain their original signatures; the catalog and manifest bind their exact bytes.
The completed package is verified before a ZIP is produced.

```powershell
pwsh -NoProfile -File Tools\windows\package.ps1 -Command Build `
  -Version 1.2.3 `
  -WinghosttyRoot $env:GRAPHCODE_WINGHOSTTY_ROOT `
  -ZmxRoot $env:GRAPHCODE_ZMX_ROOT `
  -SignCertificate $env:GRAPHCODE_SIGNER_THUMBPRINT `
  -SignTimestampUrl $env:GRAPHCODE_SIGN_TIMESTAMP_URL

pwsh -NoProfile -File Tools\windows\package.ps1 -Command Verify `
  -Package .build\windows\packages\GraphCode-1.2.3-windows-x86_64.zip `
  -TrustedSignerThumbprint $env:GRAPHCODE_SIGNER_THUMBPRINT

pwsh -NoProfile -File Tools\windows\package.ps1 -Command Upgrade `
  -Package .build\windows\packages\GraphCode-1.2.3-windows-x86_64.zip `
  -TrustedSignerThumbprint $env:GRAPHCODE_SIGNER_THUMBPRINT
```

Obtain the 40-hex-digit publisher certificate thumbprint through an independently
trusted release policy, **never from the downloaded package or its checksum
sidecar**. Signed packages require that explicit pin for `Verify`, `Install`,
and `Upgrade`. Supplying it also rejects unsigned packages, including a package
whose signing metadata and catalog have been stripped. Windows must report a
valid Authenticode signature, the catalog must use SHA-256 and match the files,
and the catalog and executables must match the expected publisher. A valid
signature from a different publisher is not sufficient. Verification needs only
Windows PowerShell security cmdlets; the SDK is optional on the target machine.
Installation re-verifies the staged copy before altering the existing install,
scheduled task, shortcut, or PATH.

Use a trusted RFC 3161 timestamp service via `-SignTimestampUrl` for releases.
Certificate provisioning, publisher-pin distribution/rotation, timestamp service
selection, provider release-ref retention, and publication remain release-owner
prerequisites. This catalog support does not create an installer, publish an
artifact, or enable automatic download/install/relaunch in the native updater.
Older EXE-only signed packages without a catalog are deliberately rejected.

`Packaging.Signing.Tests.ps1` exercises real Windows catalogs and tampering of
DLLs, metadata, manifests, file sets, and checksums. Its OS signature-trust
decisions are simulated without modifying certificate stores; it is not a
production Authenticode or signed-installer lifecycle proof. It runs before the
existing real-product packaging/lifecycle suite under `validate.ps1 -Task packaging`.

## Retained provider sources

Both exact public provider pins have the annotated source-retention tag
`graphcode-windows-baseline-2026-09-17`:

| Provider | Pinned commit | Retained branch |
|---|---|---|
| [coneilen/winghostty](https://github.com/coneilen/winghostty/tree/graphcode-windows-baseline-2026-09-17) | `f5abc059e4ca58b376eb209313aca7784659c679` | `graphcode-host` |
| [coneilen/zmx](https://github.com/coneilen/zmx/tree/graphcode-windows-baseline-2026-09-17) | `029e11d2b19162fb3bdf90c8270237d303b8bfb4` | `graphcode-quickchat-hang` |

As verified on 2026-09-17, each fork has an active ruleset forbidding updates or
deletion of `refs/tags/graphcode-windows-*`, without bypass actors. Separate
active rulesets prevent deletion and non-fast-forward changes of the branches
above; normal forward development is allowed. The Winghostty tag/branch ruleset
IDs are `23625509`/`23625510`; zmx's are `23625508`/`23625511`.
Administrators can still change rulesets or repository availability; these
settings are retention controls, not an irrevocable archival guarantee.

These tags preserve source, not signed product releases. No installer or binary
asset is published by creating them. Public CI can fetch them without provider
credentials; collaborator permissions were not changed.

`graphcode-windows\provider-pins.json` remains the source of truth. Bootstrap and
packaging still use exact commit SHAs, not moving branch or tag resolution.
The terminal gate checks every provider field against its investigation copy,
including repository, remote URL, SHA, artifact path, and Zig version.
`ProviderPins.Tests.ps1` proves drift in either file is rejected, while JSON
property order and explanatory fallback wording are immaterial. Run it directly
or through `validate.ps1 -Task terminal-gate`.
