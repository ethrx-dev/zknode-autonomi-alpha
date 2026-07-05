# Wiki Search

Search the P2P Foundation wiki archive using the llm-wiki
full-text search engine (BM25 scoring with tantivy).

>>How to Search

This node runs llm-wiki on port 18765. Connect over the LAN
or via the mixnet to perform searches:

   ```
   curl http://198.51.100.2:18765/search?q=<query>
   ```

Or use the llm-wiki CLI directly on this node:
   ```
   /tmp/llm-wiki search "mesh network"
   ```

>>Browse by Category

[Concepts|/wiki/concepts.mu]
[People|/wiki/people.mu]
[Organizations|/wiki/organizations.mu]
[Publications|/wiki/publications.mu]

>>Full-Text Search

The llm-wiki engine indexes page titles, body text, and tags
using BM25 ranking. All 500 wiki pages are searchable.

For mesh-native search, send an LXMF message to this node
with the query and you will receive results by reply.

>>Search via Autonomi

All wiki content is stored on the Autonomi network:
   Address: `6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848`

Download the full archive, extract, and search locally:
   ```
   ant file download 6c6fc79..2848 -o wiki.tar.gz
   tar xzf wiki.tar.gz
   grep -ri "mesh network" wiki/
   ```

[Back to Home|/index.mu]
