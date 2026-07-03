package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/crypto/blake2b"
)

type ChunkInfo struct {
	Index    uint64 `json:"index"`
	Size     int64  `json:"size"`
	Hash     string `json:"hash"`
}

type Challenge struct {
	Index     uint64 `json:"index"`
	Nonce     string `json:"nonce"`
}

type ProofResponse struct {
	Index        uint64   `json:"index"`
	Value        []byte   `json:"value"`
	MerklePath   []string `json:"merkle_path"`
	Root         string   `json:"root"`
	TotalChunks  uint64   `json:"total_chunks"`
	ChunkSize    int64    `json:"chunk_size"`
}

type Status struct {
	ChunkDir      string `json:"chunk_dir"`
	TotalChunks   uint64 `json:"total_chunks"`
	MerkleRoot    string `json:"merkle_root"`
	ChunkSize     int64  `json:"chunk_size"`
}

var (
	chunkDir   string
	chunkSize  int64
	treeMu     sync.RWMutex
	merkleTree [][32]byte
	merkleRoot [32]byte
	chunkCount uint64
)

func main() {
	dir := flag.String("dir", "/var/lib/ant-node/chunks", "chunk directory")
	size := flag.Int64("chunk-size", 1024, "chunk segment size")
	listen := flag.String("listen", ":9201", "listen address")
	flag.Parse()

	chunkDir = *dir
	chunkSize = *size

	if err := rebuildTree(); err != nil {
		log.Fatalf("build tree: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/status", statusHandler)
	mux.HandleFunc("/challenge", challengeHandler)
	mux.HandleFunc("/prove", proveHandler)

	log.Printf("storage-proved: listening on %s, dir=%s chunks=%d root=%s", 
		*listen, chunkDir, chunkCount, hex.EncodeToString(merkleRoot[:]))
	log.Fatal(http.ListenAndServe(*listen, mux))
}

func rebuildTree() error {
	treeMu.Lock()
	defer treeMu.Unlock()

	entries, err := os.ReadDir(chunkDir)
	if err != nil {
		return fmt.Errorf("read dir: %w", err)
	}

	var leafHashes [][32]byte
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		path := filepath.Join(chunkDir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		h := blake2b.Sum256(data)
		leafHashes = append(leafHashes, h)
	}

	if len(leafHashes) == 0 {
		merkleRoot = blake2b.Sum256([]byte("empty"))
		merkleTree = nil
		chunkCount = 0
		return nil
	}

	merkleTree = buildMerkleTree(leafHashes)
	merkleRoot = merkleTree[len(merkleTree)-1]
	chunkCount = uint64(len(leafHashes))
	return nil
}

func buildMerkleTree(leaves [][32]byte) [][32]byte {
	if len(leaves) == 0 {
		return [][32]byte{blake2b.Sum256([]byte("empty"))}
	}
	nodes := make([][32]byte, len(leaves)*2-1)
	copy(nodes[:len(leaves)], leaves)
	for i := len(leaves); i < len(nodes); i++ {
		left := nodes[2*i+1-len(leaves)]
		right := nodes[2*i+2-len(leaves)]
		combined := append(left[:], right[:]...)
		nodes[i] = blake2b.Sum256(combined)
	}
	return nodes
}

func getMerklePath(index uint64, tree [][32]byte, leaves int) []string {
	var path []string
	idx := int(index)
	for idx < leaves-1 {
		var sibling int
		if idx%2 == 0 {
			sibling = idx + 1
		} else {
			sibling = idx - 1
		}
		if sibling < leaves {
			path = append(path, hex.EncodeToString(tree[sibling][:]))
		}
		idx = (idx + leaves) / 2
	}
	return path
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	treeMu.RLock()
	defer treeMu.RUnlock()
	json.NewEncoder(w).Encode(Status{
		ChunkDir:    chunkDir,
		TotalChunks: chunkCount,
		MerkleRoot:  hex.EncodeToString(merkleRoot[:]),
		ChunkSize:   chunkSize,
	})
}

func challengeHandler(w http.ResponseWriter, r *http.Request) {
	treeMu.RLock()
	defer treeMu.RUnlock()

	if chunkCount == 0 {
		http.Error(w, "no chunks", http.StatusNotFound)
		return
	}

	var nonce [16]byte
	rand.Read(nonce[:])
	idx := uint64(0)
	for i := 0; i < 8; i++ {
		idx = idx<<8 | uint64(nonce[i])
	}
	idx %= chunkCount

	json.NewEncoder(w).Encode(Challenge{
		Index: idx,
		Nonce: hex.EncodeToString(nonce[:]),
	})
}

func proveHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	var chal Challenge
	if err := json.NewDecoder(r.Body).Decode(&chal); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	treeMu.RLock()
	defer treeMu.RUnlock()

	if chal.Index >= chunkCount {
		http.Error(w, "index out of range", http.StatusBadRequest)
		return
	}

	entries, _ := os.ReadDir(chunkDir)
	var targetFile string
	var fileIdx uint64
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if fileIdx == chal.Index {
			targetFile = filepath.Join(chunkDir, e.Name())
			break
		}
		fileIdx++
	}

	if targetFile == "" {
		http.Error(w, "chunk not found", http.StatusNotFound)
		return
	}

	data, err := os.ReadFile(targetFile)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	leaf := blake2b.Sum256(data)
	path := getMerklePath(chal.Index, merkleTree, int(chunkCount))

	resp := ProofResponse{
		Index:       chal.Index,
		Value:       leaf[:],
		MerklePath:  path,
		Root:        hex.EncodeToString(merkleRoot[:]),
		TotalChunks: chunkCount,
		ChunkSize:   chunkSize,
	}

	json.NewEncoder(w).Encode(resp)
}


