mod config;
mod poller;
mod response;
mod types;

use anyhow::Result;
use clap::Parser;
use reqwest::Client;
use tokio::signal;

#[derive(Parser, Debug)]
#[command(name = "grafana-to-go")]
#[command(about = "prometeus proxy exporter or curl jq queries", long_about = None)]
struct Cli {
    /// Path to the YAML config file
    #[arg(short, long)]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = config::load_config(&cli.config)?;
    println!("Loaded config: {:#?}", config);

    let client = Client::new();

    for target in config.targets {
        let client = client.clone();
        tokio::spawn(async move {
            poller::start_poller(target, client).await;
        });
    }

    println!("Press Ctrl+C to exit");
    signal::ctrl_c().await?;
    println!("Received Ctrl+C, shutting down");

    Ok(())
}

