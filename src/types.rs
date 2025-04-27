use serde::Deserialize;
use std::collections::HashMap;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub targets: Vec<Target>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub name: String,
    pub uri: String,
    #[serde(default = "default_method")]
    pub method: String,
    #[serde(default)]
    pub include_auth_header: bool,
    pub headers: Option<HashMap<String, String>>,
    pub form_params: Option<HashMap<String, String>>,
    pub period_seconds: u64,
    pub metrics: Vec<MetricDef>,
}

fn default_method() -> String {
    "GET".to_string()
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
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
#[serde(rename_all = "camelCase")]
pub struct LabelQuery {
    pub name: String,
    pub query: String,
}
