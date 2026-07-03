use clap::Parser;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

mod prover;

#[derive(Parser)]
#[command(name = "storage-proved-rs")]
struct Cli {
    #[arg(short, long, default_value = "/var/lib/ant-node/chunks")]
    dir: PathBuf,

    #[arg(short, long, default_value_t = 1024)]
    chunk_size: usize,

    #[arg(short, long, default_value = "127.0.0.1:9201")]
    listen: String,
}

#[derive(Clone)]
struct AppState {
    prover: Arc<RwLock<prover::StorageProver>>,
    chunk_dir: PathBuf,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let prover = prover::StorageProver::new(&cli.dir, cli.chunk_size)
        .await
        .expect("failed to initialize storage prover");

    let state = AppState {
        prover: Arc::new(RwLock::new(prover)),
        chunk_dir: cli.dir,
    };

    let app = axum::Router::new()
        .route("/status", axum::routing::get(status_handler))
        .route("/challenge", axum::routing::get(challenge_handler))
        .route("/prove", axum::routing::post(prove_handler))
        .route("/verify", axum::routing::post(verify_handler))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&cli.listen)
        .await
        .expect("bind");

    println!("storage-proved-rs: listening on {}", cli.listen);
    axum::serve(listener, app).await.unwrap();
}

#[derive(serde::Serialize)]
struct StatusResponse {
    chunk_dir: String,
    total_chunks: usize,
    merkle_root: String,
    chunk_size: usize,
}

async fn status_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> axum::Json<StatusResponse> {
    let p = state.prover.read().await;
    axum::Json(StatusResponse {
        chunk_dir: state.chunk_dir.display().to_string(),
        total_chunks: p.total_chunks(),
        merkle_root: hex::encode(p.merkle_root()),
        chunk_size: p.chunk_size(),
    })
}

#[derive(serde::Serialize)]
struct ChallengeResponse {
    index: usize,
    nonce: String,
}

async fn challenge_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> axum::Json<ChallengeResponse> {
    let p = state.prover.read().await;
    let index = p.random_challenge();
    let nonce = hex::encode(index.to_le_bytes());
    axum::Json(ChallengeResponse { index, nonce })
}

#[derive(serde::Deserialize, serde::Serialize)]
struct ProveRequest {
    index: usize,
}

#[derive(serde::Serialize)]
struct ProveResponse {
    index: usize,
    leaf: String,
    merkle_root: String,
    proof: Vec<u8>,
    proof_size: usize,
    total_chunks: usize,
}

async fn prove_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
    axum::extract::Json(req): axum::extract::Json<ProveRequest>,
) -> Result<axum::Json<ProveResponse>, axum::http::StatusCode> {
    let p = state.prover.read().await;

    if req.index >= p.total_chunks() {
        return Err(axum::http::StatusCode::BAD_REQUEST);
    }

    let (proof, leaf) = p.prove(req.index)
        .map_err(|_| axum::http::StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(axum::Json(ProveResponse {
        index: req.index,
        leaf: hex::encode(leaf),
        merkle_root: hex::encode(p.merkle_root()),
        proof: proof.clone(),
        proof_size: proof.len(),
        total_chunks: p.total_chunks(),
    }))
}

#[derive(serde::Deserialize)]
struct VerifyRequest {
    proof: Vec<u8>,
    merkle_root: String,
}

#[derive(serde::Serialize)]
struct VerifyResponse {
    verified: bool,
}

async fn verify_handler(
    axum::extract::Json(req): axum::extract::Json<VerifyRequest>,
) -> axum::Json<VerifyResponse> {
    let root_bytes = hex::decode(&req.merkle_root).unwrap_or_default();
    let mut root = [0u8; 32];
    root[..root_bytes.len().min(32)].copy_from_slice(&root_bytes[..root_bytes.len().min(32)]);

    let verified = prover::verify_proof(&req.proof, &root);
    axum::Json(VerifyResponse { verified })
}
