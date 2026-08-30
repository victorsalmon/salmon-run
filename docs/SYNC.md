# Canonical synchronization

The public `salmon-run` repository is the source of truth for the engine, schemas, shared modules, executor contracts, public tests, and public documentation.

Private deployments are consumers. `scripts/public-to-private.manifest.json` is the complete allowlist of shared paths and their private destinations. `scripts/Sync-ToPrivate.ps1` copies those files one way without deleting unlisted files. It refuses targets under protected private areas such as runtime queues, internal docs, plugins, credentials, and environment configuration.

```powershell
./scripts/Sync-ToPrivate.ps1 -PrivateRepo <private-repo> -Verify
./scripts/Test-PrivateParity.ps1 -PrivateRepo <private-repo>
```

`SALMON_PRIVATE_REPO` may supply the private path. `-WhatIf` previews a sync. `-Verify` hashes every manifest-listed public file against its consumer copy. Drift or a missing copy fails the command.

`Sync-FromCanonical.ps1` is intentionally retired. Bidirectional synchronization and private-to-public projection are not supported.

The public leak check remains mandatory before release. Sync never copies credentials, deployment-only extensions, runtime `Tasks`, or internal documentation because those paths are absent from the manifest and protected in policy.
