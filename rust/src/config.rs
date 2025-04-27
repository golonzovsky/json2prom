use crate::types::Config;
use anyhow::Result;
use std::fs::File;
use std::io::BufReader;

/// Load and parse the YAML config from the given path
pub fn load_config(path: &str) -> Result<Config> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let config: Config = serde_yaml::from_reader(reader)?;
    Ok(config)
}

