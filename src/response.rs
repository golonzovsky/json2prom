use crate::types::Target;

use jaq_core::{Compiler, Ctx, RcIter, load};
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

pub fn extract_metrics(target: &Target, body: &str) -> Vec<(String, Vec<String>, f64)> {
    let mut results = Vec::new();
    if let Ok(json) = serde_json::from_str::<Value>(body) {
        for metric in &target.metrics {
            for item in run_jq(&json, &metric.items_query) {
                let item_val: Value =
                    serde_json::from_str(&item.to_string()).unwrap_or(Value::Null);
                for v in run_jq(&item_val, &metric.value_query) {
                    let value = v.as_f64().unwrap_or(0.0);
                    let mut labels = vec![target.name.clone()];
                    if let Some(lbls) = &metric.labels {
                        for lbl in lbls {
                            let s = run_jq(&item_val, &lbl.query)
                                .first()
                                .map(|x| match x {
                                    Val::Str(st) => st.to_string(),
                                    _ => x.to_string(),
                                })
                                .unwrap_or_default();
                            labels.push(s);
                        }
                    }
                    results.push((metric.name.clone(), labels, value));
                }
            }
        }
    }
    results
}
