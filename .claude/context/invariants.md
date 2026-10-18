# Repository binding

- Same-named repositories at distinct canonical paths must never share stake selection or lineage.
- Verify the signed repository path before PIV unwrap.
- Recheck binding before creating workspace state.
- Paths are exact canonical Git roots; missing, relative, or moved paths fail closed.
- Listing by name is display filtering only.
