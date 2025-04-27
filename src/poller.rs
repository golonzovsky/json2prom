use crate::response::extract_metrics;
use crate::types::Target;

use prometheus::{GaugeVec, Opts, Registry};
use reqwest::Client;
use reqwest::header;
use std::sync::Arc;
use std::time::Duration;
use tokio::time;
use tracing::debug;

pub struct Poller {
    target: Target,
    gauges: Vec<(String, GaugeVec, Vec<String>)>,
}

impl Poller {
    pub fn new(target: Target, registry: Arc<Registry>) -> Self {
        if target.include_auth_header {
            std::env::var("AUTH_TOKEN")
                .expect("auth token requested but env var AUTH_TOKEN not set");
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
            let gv = GaugeVec::new(
                opts,
                &label_names.iter().map(String::as_str).collect::<Vec<_>>(),
            )
            .expect("invalid labels");
            registry.register(Box::new(gv.clone())).unwrap();
            gauges.push((name, gv, label_names));
        }
        Poller { target, gauges }
    }

    pub async fn run(self, client: Client) {
        let mut interval = time::interval(Duration::from_secs(self.target.period_seconds));
        loop {
            interval.tick().await;
            debug!("Sending request: {:?}", &self.target.uri);

            // Build request
            let mut req = client.request(self.target.method.parse().unwrap(), &self.target.uri);

            if self.target.include_auth_header {
                let token = std::env::var("AUTH_TOKEN").unwrap();
                req = req.header(header::AUTHORIZATION, format!("Bearer {}", token));
            }

            if let Some(hdrs) = &self.target.headers {
                for (k, v) in hdrs {
                    req = req.header(k.as_str(), v.as_str());
                }
            }

            if let Some(params) = &self.target.form_params {
                req = req.form(params);
            }

            if let Ok(resp) = req.send().await {
                if let Ok(body) = resp.text().await {
                    debug!("Got resp: {:?}", &body);

                    let metrics = extract_metrics(&self.target, &body);
                    for (metric_name, label_values, value) in metrics {
                        debug!("Processing metric: {:?}={:?}", &metric_name, &value);
                        for (name, gv, _) in &self.gauges {
                            if name == &metric_name {
                                debug!("Update gauge: name={:?} ", &name);
                                let label_strs: Vec<&str> =
                                    label_values.iter().map(String::as_str).collect();
                                gv.with_label_values(&label_strs).set(value);
                            }
                        }
                    }
                }
            }
        }
    }
}
