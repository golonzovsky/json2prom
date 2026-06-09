use crate::config::MetricDef;

use anyhow::{Result, anyhow};
use jaq_core::data::JustLut;
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{Ctx, Vars};
use jaq_json::Val;
use jaq_std::ValT as _;
use tracing::warn;

type Filter = jaq_core::Filter<JustLut<Val>>;

fn compile(query: &str) -> Result<Filter> {
    let loader = Loader::new(
        jaq_core::defs()
            .chain(jaq_std::defs())
            .chain(jaq_json::defs()),
    );
    let arena = Arena::default();
    let modules = loader
        .load(
            &arena,
            File {
                code: query,
                path: (),
            },
        )
        .map_err(|errs| anyhow!("failed to parse jq query '{query}': {errs:?}"))?;
    jaq_core::Compiler::default()
        .with_funs(
            jaq_core::funs()
                .chain(jaq_std::funs())
                .chain(jaq_json::funs()),
        )
        .compile(modules)
        .map_err(|errs| anyhow!("failed to compile jq query '{query}': {errs:?}"))
}

fn run(filter: &Filter, input: Val) -> impl Iterator<Item = Val> {
    let ctx = Ctx::<JustLut<Val>>::new(&filter.lut, Vars::new([]));
    filter.id.run((ctx, input)).filter_map(Result::ok)
}

fn first(filter: &Filter, input: Val) -> Option<Val> {
    run(filter, input).next()
}

fn label_value(val: Val) -> String {
    match val {
        Val::TStr(s) | Val::BStr(s) => String::from_utf8_lossy(&s).into_owned(),
        other => other.to_string(),
    }
}

pub struct MetricExtractor {
    name: String,
    items: Filter,
    value: Filter,
    labels: Vec<Filter>,
}

impl MetricExtractor {
    pub fn compile(def: &MetricDef) -> Result<Self> {
        Ok(Self {
            name: def.name.clone(),
            items: compile(&def.items_query)?,
            value: compile(&def.value_query)?,
            labels: def
                .labels
                .iter()
                .flatten()
                .map(|label| compile(&label.query))
                .collect::<Result<_>>()?,
        })
    }

    pub fn extract(&self, root: &Val) -> Vec<(Vec<String>, f64)> {
        let mut samples = Vec::new();
        for item in run(&self.items, root.clone()) {
            let value = match first(&self.value, item.clone()) {
                Some(Val::Bool(b)) => {
                    if b {
                        1.0
                    } else {
                        0.0
                    }
                }
                Some(val) => match val.as_f64() {
                    Some(value) => value,
                    None => {
                        warn!("metric '{}': skipping non-numeric value {val}", self.name);
                        continue;
                    }
                },
                None => {
                    warn!(
                        "metric '{}': value query yielded no result, skipping",
                        self.name
                    );
                    continue;
                }
            };
            let labels = self
                .labels
                .iter()
                .map(|filter| {
                    first(filter, item.clone())
                        .map(label_value)
                        .unwrap_or_default()
                })
                .collect();
            samples.push((labels, value));
        }
        samples
    }
}
