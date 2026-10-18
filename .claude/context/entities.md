# Vault entities

StakeManifest signs repoPathHint alongside image digests and parent linkage. WorkspaceRecord persists the selected host repoPath. VaultStore owns generation and tag uniqueness. Repository path equality must hold across selection, lineage, and workspace creation.
