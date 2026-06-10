mod config;
mod extract;
mod poller;
#[cfg(test)]
mod tests;

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use axum::{Router, extract::State, http::StatusCode, routing::get};
use clap::Parser;
use prometheus::{Registry, TextEncoder};
use reqwest::Client;
use tokio::signal;
use tokio::task::JoinSet;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "json2prom")]
#[command(about = "prometheus exporter for JSON HTTP APIs via jq queries")]
struct Args {
    #[arg(short, long, default_value = "config.yaml")]
    config: PathBuf,

    #[arg(long, default_value = "0.0.0.0:9100")]
    listen: String,
}

async fn metrics_handler(State(registry): State<Registry>) -> Result<String, (StatusCode, String)> {
    TextEncoder::new()
        .encode_to_string(&registry.gather())
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to encode metrics: {e}"),
            )
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let args = Args::parse();
    let config = config::load_config(&args.config)
        .with_context(|| format!("Failed to load config from {}", args.config.display()))?;

    info!("Loaded {} targets from config", config.targets.len());

    let registry = Registry::new();
    let client = Client::builder()
        .gzip(true)
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("Failed to create HTTP client")?;

    let mut pollers = spawn_pollers(config.targets, &registry, &client)?;

    tokio::select! {
        res = serve_metrics(args.listen, registry) => res,
        Some(res) = pollers.join_next() => match res {
            Ok(()) => bail!("poller task exited unexpectedly"),
            Err(e) => Err(e).context("poller task failed"),
        },
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

fn spawn_pollers(
    targets: Vec<config::Target>,
    registry: &Registry,
    client: &Client,
) -> Result<JoinSet<()>> {
    let mut pollers = JoinSet::new();
    for target in targets {
        let poller = poller::Poller::new(target, registry)?;
        let client = client.clone();
        pollers.spawn(async move { poller.run(client).await });
    }
    Ok(pollers)
}

async fn shutdown_signal() {
    let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())
        .expect("failed to install SIGTERM handler");
    tokio::select! {
        _ = signal::ctrl_c() => {}
        _ = sigterm.recv() => {}
    }
    info!("Received shutdown signal");
}

async fn serve_metrics(listen: String, registry: Registry) -> Result<()> {
    let app = Router::new()
        .route("/metrics", get(metrics_handler))
        .route("/health", get(|| async { "OK" }))
        .with_state(registry);

    let listener = tokio::net::TcpListener::bind(&listen)
        .await
        .with_context(|| format!("Failed to bind to {listen}"))?;

    info!(
        "Serving metrics on http://{}/metrics",
        listener.local_addr()?
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("Server error")
}
