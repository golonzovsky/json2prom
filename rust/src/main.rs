mod config;
mod poller;
mod response;
#[cfg(test)]
mod tests;

use std::io;
use std::sync::Arc;

use anyhow::Result;
use axum::{Router, routing::get};
use clap::Parser;
use prometheus::{Encoder, Registry, TextEncoder};
use reqwest::Client;
use tokio::signal;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "grafana-to-go")]
#[command(about = "prometeus proxy exporter or curl jq queries", long_about = None)]
struct Cli {
    /// Path to the YAML config file
    #[arg(short, long)]
    config: String,
}

async fn metrics_handler(registry: Arc<Registry>) -> String {
    let families = registry.gather();
    let encoder = TextEncoder::new();
    let mut buf = Vec::new();
    encoder.encode(&families, &mut buf).unwrap();
    String::from_utf8(buf).unwrap()
}

#[tokio::main]
async fn main() -> Result<()> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter(filter)
        .init();

    let cli = Cli::parse();
    let config = config::load_config(&cli.config)?;
    info!("Loaded config: {:#?}", config);

    let registry = Arc::new(Registry::new());
    let client = Client::new();
    let mut app = Router::new();

    for target in config.targets {
        let poller = poller::Poller::new(target, registry.clone());
        let cli = client.clone();
        tokio::spawn(async move {
            poller.run(cli).await;
        });
    }
    app = app.route("/metrics", get(move || metrics_handler(registry.clone())));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:9100").await?;
    info!("Serving metrics on {}/metrics", listener.local_addr()?);

    tokio::select! {
        _ = axum::serve(listener, app) => {},
        _ = signal::ctrl_c() => info!("Shutting down"),
    }
    Ok(())
}
