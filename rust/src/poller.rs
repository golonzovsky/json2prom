use crate::config::Target;
use crate::response::extract_metrics;

use anyhow::{Context, Result};
use prometheus::{GaugeVec, Opts, Registry};
use reqwest::{Client, header};
use std::sync::Arc;
use std::time::Duration;
use tokio::time;
use tracing::{debug, error, warn};

pub struct Poller {
    target: Target,
    gauges: Vec<(String, GaugeVec, Vec<String>)>,
}

impl Poller {
    pub fn new(target: Target, registry: Arc<Registry>) -> Result<Self> {
        if let Some(token_env) = &target.use_bearer_token_from {
            std::env::var(token_env).with_context(|| {
                format!("Bearer token environment variable '{}' not set", token_env)
            })?;
        }
        let mut gauges = Vec::new();
        for metric in &target.metrics {
            // Metric name
            let name = metric.name.clone();
            // Build label names vector (first `target`, then any extra)
            let mut label_names = vec!["target".to_string()];
            if let Some(lbls) = &metric.labels {
                for lbl in lbls {
                    label_names.push(lbl.name.clone());
                }
            }
            // Create the GaugeVec and register it
            let opts = Opts::new(&name, format!("Metric {}", &name));
            let label_refs: Vec<&str> = label_names.iter().map(String::as_str).collect();
            let gv = GaugeVec::new(opts, &label_refs)
                .with_context(|| format!("Failed to create gauge for metric '{}'", name))?;
            registry
                .register(Box::new(gv.clone()))
                .with_context(|| format!("Failed to register metric '{}'", name))?;
            gauges.push((name, gv, label_names));
        }
        Ok(Poller { target, gauges })
    }

    pub async fn run(self, client: Client) {
        let mut interval = time::interval(Duration::from_secs(self.target.period_seconds));
        loop {
            interval.tick().await;
            debug!("Sending request to {:?}", &self.target.uri);

            // Build request
            let method = reqwest::Method::from_bytes(self.target.method.as_str().as_bytes())
                .expect("Invalid HTTP method");
            let mut req = client.request(method, &self.target.uri);

            if let Some(token_env) = &self.target.use_bearer_token_from {
                match std::env::var(token_env) {
                    Ok(token) => {
                        req = req.header(header::AUTHORIZATION, format!("Bearer {}", token));
                    }
                    Err(e) => {
                        error!("Failed to get bearer token from {}: {}", token_env, e);
                        continue;
                    }
                }
            }

            if let Some(hdrs) = &self.target.headers {
                for (k, v) in hdrs {
                    req = req.header(k.as_str(), v.as_str());
                }
            }

            if let Some(params) = &self.target.form_params {
                req = req.form(params);
            }

            match req.send().await {
                Ok(resp) => {
                    if !resp.status().is_success() {
                        warn!("HTTP request failed with status: {}", resp.status());
                        continue;
                    }
                    match resp.text().await {
                        Ok(body) => {
                            debug!("Got response: {:?}", &body);
                            self.update_metrics(&body);
                        }
                        Err(e) => error!("Failed to read response body: {}", e),
                    }
                }
                Err(e) => error!("Failed to send request to {}: {}", self.target.uri, e),
            }
        }
    }

    fn update_metrics(&self, body: &str) {
        let metrics = extract_metrics(&self.target, body);
        for (metric_name, label_values, value) in metrics {
            debug!("Processing metric: {}={}", &metric_name, value);
            for (name, gv, _) in &self.gauges {
                if name == &metric_name {
                    let label_refs: Vec<&str> = label_values.iter().map(String::as_str).collect();
                    gv.with_label_values(&label_refs).set(value);
                }
            }
        }
    }
}
