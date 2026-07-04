# Wiki Archives on Autonomi

The P2P Foundation wiki is archived on the Autonomi network.
Each snapshot is stored as a content-addressed archive with
permanent availability.

>>Latest Archive

* Latest snapshot: `p2p-foundation-wiki-latest` (Autonomi pointer)
* Format: Markdown with YAML frontmatter
* Access: `ant file download <address> --output wiki.tar.gz`

>>How to Access

1. Install the Autonomi CLI: `pip install autonomi-cli`
2. Set your SECRET_KEY and EVM network
3. Query the wiki pointer:
   ```
   ant pointer get p2p-foundation-wiki-latest
   ```
4. Download and extract:
   ```
   ant file download <address> -o wiki.tar.gz
   tar xzf wiki.tar.gz
   ```

>>Snapshots

Full wiki snapshots are published weekly.

[Back to Home|/index.mu]
