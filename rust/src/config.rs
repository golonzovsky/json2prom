use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub targets: Vec<Target>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Target {
    pub name: String,
    pub uri: String,
    #[serde(default = "default_method")]
    pub method: String,
    pub use_bearer_token_from: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub form_params: Option<HashMap<String, String>>,
    pub period_seconds: u64,
    pub metrics: Vec<MetricDef>,
}

fn default_method() -> String {
    "GET".to_string()
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetricDef {
    pub name: String,
    #[serde(default = "default_items_query")]
    pub items_query: String,
    pub value_query: String,
    pub labels: Option<Vec<LabelQuery>>,
}

fn default_items_query() -> String {
    ".".to_string()
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LabelQuery {
    pub name: String,
    pub query: String,
}

/// Load and parse the YAML config from the given path
pub fn load_config(path: &str) -> Result<Config> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let config: Config = serde_yaml::from_reader(reader)?;
    Ok(config)
}
