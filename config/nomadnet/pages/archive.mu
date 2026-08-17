# Wiki Archives on Autonomi

The P2P Foundation wiki is archived on the Autonomi network.
Each snapshot is stored as a content-addressed archive with
permanent availability.

>>Current Archive

* Latest Autonomi address:
  `6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848`
* Content: ~500 markdown pages (866 KB)
* Format: Markdown with YAML frontmatter

>>How to Access Over LAN

From any machine on the local network:
   ```
   ant file download 6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848 -o wiki.tar.gz
   tar xzf wiki.tar.gz
   ```

Requires the Autonomi CLI and a connection to the local devnet.
See the About page for connection details.

>>How to Access Over Mesh

Via NomadNet search:
1. Use the [Search page|/search.mu] to find wiki content
2. Results are served over the Reticulum mesh

>>Auto-Sync

This node automatically syncs the wiki from Autonomi every hour.
The llm-wiki search index is rebuilt on each sync.

>>Snapshots

Full wiki snapshots are published to Autonomi on each update.
The latest address is always shown at the top of this page.

[Back to Home|/index.mu]
