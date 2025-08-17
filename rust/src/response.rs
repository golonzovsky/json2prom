use crate::config::Target;

use jaq_core::{Compiler, Ctx, RcIter, load};
use jaq_json::Val;
use jaq_std::{ValT, defs, funs};
use load::{Arena, File, Loader};
use serde_json::Value;
use tracing::{debug, warn};

fn run_jq(input: &Value, query: &str) -> Vec<Val> {
    let loader = Loader::new(defs().chain(jaq_json::defs()));
    let arena = Arena::default();

    let modules = match loader.load(
        &arena,
        File {
            code: query,
            path: (),
        },
    ) {
        Ok(modules) => modules,
        Err(e) => {
            warn!("Failed to parse jq query '{}': {:?}", query, e);
            return Vec::new();
        }
    };

    let filter = match Compiler::default()
        .with_funs(funs().chain(jaq_json::funs()))
        .compile(modules)
    {
        Ok(filter) => filter,
        Err(e) => {
            warn!("Failed to compile jq query '{}': {:?}", query, e);
            return Vec::new();
        }
    };

    let inputs = RcIter::new(std::iter::empty());
    let ctx = Ctx::new([], &inputs);

    filter
        .run((ctx, Val::from(input.clone())))
        .filter_map(Result::ok)
        .collect()
}

fn parse_json(body: &str) -> Option<Value> {
    match serde_json::from_str::<Value>(body) {
        Ok(json) => Some(json),
        Err(e) => {
            debug!("Failed to parse JSON response: {}", e);
            None
        }
    }
}

fn extract_label(item: &Value, query: &str) -> String {
    run_jq(item, query)
        .first()
        .map(|val| match val {
            Val::Str(s) => s.to_string(),
            _ => val.to_string(),
        })
        .unwrap_or_default()
}

pub fn extract_metrics(target: &Target, body: &str) -> Vec<(String, Vec<String>, f64)> {
    let Some(json) = parse_json(body) else {
        return Vec::new();
    };

    let mut results = Vec::new();

    for metric in &target.metrics {
        let items = run_jq(&json, &metric.items_query);
        if items.is_empty() {
            debug!(
                "No items found for metric '{}' with query '{}'",
                metric.name, metric.items_query
            );
        }

        for item in items {
            let item_json: Value = serde_json::from_str(&item.to_string()).unwrap_or(Value::Null);

            let values = run_jq(&item_json, &metric.value_query);
            if values.is_empty() {
                debug!(
                    "No values found for metric '{}' with query '{}'",
                    metric.name, metric.value_query
                );
            }

            for val in values {
                let value = val.as_f64().unwrap_or_else(|_| {
                    debug!("Non-numeric value for metric '{}': {:?}", metric.name, val);
                    0.0
                });

                let mut labels = vec![target.name.clone()];

                if let Some(label_queries) = &metric.labels {
                    for label_query in label_queries {
                        labels.push(extract_label(&item_json, &label_query.query));
                    }
                }

                results.push((metric.name.clone(), labels, value));
            }
        }
    }

    results
}
