use crate::response::extract_metrics;
use crate::types::Target;
use prometheus::{GaugeVec, Opts, Registry};
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tokio::time;

pub struct Poller {
    target: Target,
    gauges: Vec<(String, GaugeVec, Vec<String>)>,
}

impl Poller {
    pub fn new(target: Target, registry: Arc<Registry>) -> Self {
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
            println!("Sending request: {:?}", &self.target.uri);

            if let Ok(resp) = client
                .request(self.target.method.parse().unwrap(), &self.target.uri)
                .send()
                .await
            {
                if let Ok(body) = resp.text().await {
                    println!("Got resp: {:?}", &body);

                    let metrics = extract_metrics(&self.target, &body);
                    for (metric_name, label_values, value) in metrics {
                        println!("Processing metric: {:?}={:?}", &metric_name, &value);
                        for (name, gv, _) in &self.gauges {
                            if name == &metric_name {
                                println!("Update gauge: name={:?} ", &name);
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
