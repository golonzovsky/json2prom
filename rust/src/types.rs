use serde::Deserialize;
use std::collections::HashMap;

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
    #[serde(default)]
    pub xml_mode: bool,
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
