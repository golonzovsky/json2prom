use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub targets: Vec<Target>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Target {
    pub name: String,
    pub uri: String,
    #[serde(default)]
    pub method: Method,
    pub use_bearer_token_from: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub form_params: Option<HashMap<String, String>>,
    pub period_seconds: u64,
    pub metrics: Vec<MetricDef>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub enum Method {
    #[serde(rename = "GET")]
    #[default]
    Get,
    #[serde(rename = "POST")]
    Post,
    #[serde(rename = "PUT")]
    Put,
    #[serde(rename = "DELETE")]
    Delete,
}

impl Method {
    pub fn as_str(&self) -> &str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Put => "PUT",
            Method::Delete => "DELETE",
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MetricDef {
    pub name: String,
    #[serde(default = "MetricDef::default_items_query")]
    pub items_query: String,
    pub value_query: String,
    pub labels: Option<Vec<LabelQuery>>,
}

impl MetricDef {
    fn default_items_query() -> String {
        ".".to_string()
    }
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct LabelQuery {
    pub name: String,
    pub query: String,
}

pub fn load_config(path: impl AsRef<Path>) -> Result<Config> {
    let contents = std::fs::read_to_string(path)?;
    let config = serde_yaml::from_str(&contents)?;
    Ok(config)
}
