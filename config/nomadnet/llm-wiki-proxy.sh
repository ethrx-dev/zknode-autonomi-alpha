#!/bin/bash
# llm-wiki ↔ NomadNet bridge: serve llm-wiki search results over Reticulum mesh
# Usage: llm-wiki-proxy.sh search <query>
# Returns a .mu formatted page with search results

LLM_WIKI="${LLM_WIKI:-/tmp/llm-wiki}"

case "${1:-help}" in
    search)
        shift
        query="$*"
        if [ -z "$query" ]; then
            echo "# Search Error"
            echo ""
            echo "Usage: provide a search query."
            echo "[Back|/search.mu]"
            exit 0
        fi

        results=$("$LLM_WIKI" search "$query" 2>/dev/null | head -40)

        echo "# Search Results for: $query"
        echo ""

        if [ -z "$results" ] || echo "$results" | grep -qi "no results"; then
            echo "No results found."
        else
            echo "$results" | while read -r line; do
                if [[ "$line" =~ ^slug: ]]; then
                    slug=$(echo "$line" | cut -d' ' -f2)
                    echo "  - [$slug|/wiki/$slug.mu]"
                elif [[ "$line" =~ ^title: ]]; then
                    title=$(echo "$line" | cut -d' ' -f2-)
                    echo "  *$title*"
                fi
            done
        fi

        echo ""
        echo "[New Search|/search.mu]"
        echo "[Back to Home|/index.mu]"
        ;;
    *)
        echo "# llm-wiki Mesh Proxy"
        echo ""
        echo "This script bridges llm-wiki search to NomadNet."
        echo ""
        echo "Usage:"
        echo "  llm-wiki-proxy search <query>"
        echo ""
        echo "Example:"
        echo "  llm-wiki-proxy search blockchain governance"
        echo ""
        echo "[Back to Home|/index.mu]"
        ;;
esac
