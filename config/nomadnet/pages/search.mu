# Wiki Search

Search the P2P Foundation wiki archive.

>>Static Search

Browse wiki pages by category:

[Concepts|/wiki/concepts.mu]
[People|/wiki/people.mu]
[Organizations|/wiki/organizations.mu]
[Publications|/wiki/publications.mu]

>>Dynamic Search

If dynamic pages are enabled, this node can execute search
queries via the llm-wiki search API:

```
llm-wiki search p2p-foundation "<query>"
```

>>Full-Text Search

The llm-wiki engine provides BM25 full-text search over the
entire wiki corpus. Connect to the MCP server at:

* TCP: `llm-wiki:18765` (internal network)
* Local: `127.0.0.1:18765` (host network)

[Back to Home|/index.mu]
