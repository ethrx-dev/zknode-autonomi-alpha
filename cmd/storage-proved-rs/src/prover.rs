use std::path::Path;
use std::fs;

/// StorageProver manages a BLAKE3 Merkle tree over storage chunks.
pub struct StorageProver {
    tree: Vec<[u8; 32]>,  // flat Merkle tree (leaves then internal nodes)
    leaves: Vec<[u8; 32]>,
    total_chunks: usize,
    chunk_size: usize,
    root: [u8; 32],
}

impl StorageProver {
    /// Build a Merkle tree over all files in a directory.
    pub async fn new(dir: &Path, chunk_size: usize) -> Result<Self, Box<dyn std::error::Error>> {
        let mut entries = Vec::new();
        let mut read_dir = tokio::fs::read_dir(dir).await?;
        while let Some(entry) = read_dir.next_entry().await? {
            if entry.file_type().await?.is_file() {
                entries.push(entry.path());
            }
        }
        entries.sort();

        let mut leaves = Vec::new();
        for path in &entries {
            let data = fs::read(path)?;
            leaves.push(blake3::hash(&data).into());
        }

        if leaves.is_empty() {
            leaves.push([0u8; 32]);
        }

        let tree = build_merkle_tree(&leaves);
        let root = tree[tree.len() - 1];

        Ok(Self {
            tree,
            leaves: leaves.clone(),
            total_chunks: leaves.len(),
            chunk_size,
            root,
        })
    }

    pub fn total_chunks(&self) -> usize {
        self.total_chunks
    }

    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    pub fn merkle_root(&self) -> &[u8; 32] {
        &self.root
    }

    pub fn random_challenge(&self) -> usize {
        if self.total_chunks == 0 {
            return 0;
        }
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos() as usize;
        nanos % self.total_chunks
    }

    /// Generate a Merkle proof (path from leaf to root).
    /// Returns (serialized_proof, leaf_hash).
    pub fn prove(&self, index: usize) -> Result<(Vec<u8>, [u8; 32]), Box<dyn std::error::Error>> {
        if index >= self.total_chunks {
            return Err("index out of range".into());
        }

        let leaf = self.leaves[index];
        let path = get_merkle_path(index, &self.tree, self.total_chunks);

        let proof_data = StorageProof {
            index,
            leaf: leaf.to_vec(),
            path: path.clone(),
            root: self.root.to_vec(),
            total_chunks: self.total_chunks as u64,
        };

        let serialized = bincode::serialize(&proof_data)?;
        Ok((serialized, leaf))
    }
}

fn build_merkle_tree(leaves: &[[u8; 32]]) -> Vec<[u8; 32]> {
    if leaves.is_empty() {
        return vec![[0u8; 32]];
    }
    let mut tree = leaves.to_vec();
    let mut offset = 0;
    let mut level_size = leaves.len();

    while level_size > 1 {
        if level_size % 2 != 0 {
            level_size += 1; // pad with duplicate of last
        }
        let mut next_level: Vec<[u8; 32]> = Vec::with_capacity(level_size / 2);
        for i in (0..level_size).step_by(2) {
            let left = if offset + i < tree.len() {
                tree[offset + i]
            } else {
                tree[tree.len() - 1]
            };
            let right = if offset + i + 1 < tree.len() {
                tree[offset + i + 1]
            } else {
                left
            };
            let mut hasher = blake3::Hasher::new();
            hasher.update(&left);
            hasher.update(&right);
            next_level.push(hasher.finalize().into());
        }
        offset += level_size;
        tree.extend(next_level);
        level_size /= 2;
    }

    tree
}

fn get_merkle_path(index: usize, tree: &[[u8; 32]], num_leaves: usize) -> Vec<Vec<u8>> {
    let mut path = Vec::new();
    let mut idx = index;
    let mut level_start = 0;
    let mut level_nodes = num_leaves;

    while level_nodes > 1 {
        let sibling_idx = if idx % 2 == 0 {
            if idx + 1 < level_nodes { idx + 1 } else { idx }
        } else {
            idx - 1
        };
        if sibling_idx < level_nodes && sibling_idx != idx {
            path.push(tree[level_start + sibling_idx].to_vec());
        }
        let next_level_nodes = (level_nodes + 1) / 2;
        level_start += level_nodes;
        idx /= 2;
        level_nodes = next_level_nodes;
    }

    path
}

/// Verify a Merkle storage proof.
pub fn verify_proof(proof_bytes: &[u8], expected_root: &[u8; 32]) -> bool {
    let proof_data: StorageProof = match bincode::deserialize(proof_bytes) {
        Ok(d) => d,
        Err(_) => return false,
    };

    if proof_data.root.as_slice() != expected_root {
        return false;
    }

    let mut current = proof_data.leaf.clone();
    let mut idx = proof_data.index;

    for sibling in &proof_data.path {
        let (left, right) = if idx % 2 == 0 {
            (&current, sibling)
        } else {
            (sibling, &current)
        };
        let mut hasher = blake3::Hasher::new();
        hasher.update(left);
        hasher.update(right);
        current = hasher.finalize().as_bytes().to_vec();
        idx /= 2;
    }

    current == proof_data.root
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StorageProof {
    index: usize,
    leaf: Vec<u8>,
    path: Vec<Vec<u8>>,
    root: Vec<u8>,
    total_chunks: u64,
}
