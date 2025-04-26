use crate::types::Target;

use jaq_core::{Compiler, Ctx, Error, FilterT, RcIter, load};
use jaq_json::Val;
use jaq_std::{ValT, defs, funs};
use serde_json::{Value, json};

use load::{Arena, File, Loader};

fn run_jq(input: &Value, query: &str) -> Vec<Val> {
    let loader = Loader::new(defs().chain(jaq_json::defs()));
    let arena = Arena::default();
    let modules = loader
        .load(
            &arena,
            File {
                code: query,
                path: (),
            },
        )
        .expect("failed to load program");
    let filter = Compiler::default()
        .with_funs(funs().chain(jaq_json::funs()))
        .compile(modules)
        .expect("failed to compile filter");
    let inputs = RcIter::new(std::iter::empty());
    let ctx = Ctx::new([], &inputs);
    filter
        .run((ctx, Val::from(input.clone())))
        .filter_map(|res| res.ok())
        .collect()
}

/// Process the HTTP response body for a target, extracting metrics
pub fn process_response(target: &Target, body: &str) {
    match serde_json::from_str::<Value>(body) {
        Ok(json) => {
            for metric in &target.metrics {
                let items = run_jq(&json, &metric.items_query);
                for item_val in items {
                    // convert item back to JSON for further queries
                    let item_json: Value =
                        serde_json::from_str(&item_val.to_string()).unwrap_or(Value::Null);

                    // extract metric value
                    for v in run_jq(&item_json, &metric.value_query) {
                        let value = v.as_f64().unwrap_or(0.0);

                        // extract labels
                        let mut labels = Vec::new();
                        if let Some(lbls) = &metric.labels {
                            for lbl in lbls {
                                let lbl_val = run_jq(&item_json, &lbl.query)
                                    .get(0)
                                    .map(|val| val.to_string())
                                    .unwrap_or_default();
                                labels.push((lbl.name.clone(), lbl_val));
                            }
                        }
                        println!(
                            "[{}] {} labels={:?} value={}",
                            target.name, metric.name, labels, value
                        );
                    }
                }
            }
        }
        Err(e) => eprintln!("[{}] JSON parse error: {}", target.name, e),
    }
}
