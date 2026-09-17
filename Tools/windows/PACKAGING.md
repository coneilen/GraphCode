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
