use crate::types::Target;

use jaq_core::{Compiler, Ctx, RcIter, load};
use jaq_json::Val;
use jaq_std::{ValT, defs, funs};
use load::{Arena, File, Loader};
use quick_xml::de::from_str;
use serde_json::Value;
use tracing::{debug, warn};

/// Run a jq query against JSON input
///
/// This function executes a jq query against the provided JSON value
/// and returns the results as a vector of values.
fn run_jq(input: &Value, query: &str) -> Vec<Val> {
    // Set up the jq loader with standard definitions
    let loader = Loader::new(defs().chain(jaq_json::defs()));
    let arena = Arena::default();
    
    // Load the query as a jq program
    let modules = loader
        .load(
            &arena,
            File {
                code: query,
                path: (),
            },
        )
        .expect("failed to load jq program");
    
    // Compile the jq filter
    let filter = Compiler::default()
        .with_funs(funs().chain(jaq_json::funs()))
        .compile(modules)
        .expect("failed to compile jq filter");
    
    // Set up empty inputs (we're only using the main input)
    let inputs = RcIter::new(std::iter::empty());
    let ctx = Ctx::new([], &inputs);
    
    // Run the filter and collect successful results
    filter
        .run((ctx, Val::from(input.clone())))
        .filter_map(Result::ok)
        .collect()
}

/// Attempts to convert a string into a JSON number
fn try_parse_number(s: &str) -> Option<Value> {
    s.parse::<f64>().ok().map(|num| {
        Value::Number(serde_json::Number::from_f64(num).unwrap_or_else(|| {
            serde_json::Number::from(0)
        }))
    })
}

/// Process XML-parsed JSON values to make them more useful
/// 
/// This converts text nodes and automatically transforms string numbers
/// to actual JSON numbers for better query processing
fn process_xml_value(value: Value) -> Value {
    match value {
        Value::Object(mut map) => {
            // Handle XML text nodes (represented as {"$text": "value"})
            if map.len() == 1 && map.contains_key("$text") {
                if let Some(text_value) = map.remove("$text") {
                    // Try to convert string values to numbers if possible
                    if let Value::String(s) = &text_value {
                        if let Some(num_value) = try_parse_number(s) {
                            return num_value;
                        }
                    }
                    return text_value;
                }
            }
            
            // Process all object entries recursively
            Value::Object(
                map.into_iter()
                   .map(|(k, v)| (k, process_xml_value(v)))
                   .collect()
            )
        },
        Value::Array(arr) => {
            // Process array elements recursively
            Value::Array(
                arr.into_iter()
                   .map(process_xml_value)
                   .collect()
            )
        },
        Value::String(s) => {
            // Try to convert string to number at this level too
            try_parse_number(&s).unwrap_or(Value::String(s))
        },
        // For other scalar values, return as is
        _ => value,
    }
}

/// Parse response body according to the target's configuration
/// 
/// If XML mode is enabled, it will try to parse as XML first, with a fallback to JSON.
/// Otherwise, it will parse as JSON only.
fn parse_body(target: &Target, body: &str) -> Option<Value> {
    if target.xml_mode {
        // Try JSON first for better compatibility
        if let Ok(json) = serde_json::from_str::<Value>(body) {
            warn!("XML mode was enabled but content was parsed as JSON");
            return Some(json);
        }
        
        // Try XML parsing
        match from_str::<Value>(body) {
            Ok(json) => {
                debug!("Successfully parsed XML to JSON");
                let processed_json = process_xml_value(json);
                debug!("Processed XML: {:?}", processed_json);
                Some(processed_json)
            },
            Err(e) => {
                warn!("Failed to parse content as either JSON or XML: {}", e);
                None
            }
        }
    } else {
        // Standard JSON parsing
        serde_json::from_str::<Value>(body)
            .map_err(|e| warn!("Failed to parse JSON: {}", e))
            .ok()
    }
}

/// Extracts a label value from a JSON object using a jq query
fn extract_label(item_val: &Value, query: &str) -> String {
    run_jq(item_val, query)
        .first()
        .map(|x| match x {
            Val::Str(st) => st.to_string(),
            _ => x.to_string(),
        })
        .unwrap_or_default()
}

/// Extract metrics from response body according to target configuration
///
/// Parses the response according to the target mode (JSON or XML),
/// then applies jq queries to extract metrics and labels.
pub fn extract_metrics(target: &Target, body: &str) -> Vec<(String, Vec<String>, f64)> {
    let mut results = Vec::new();
    
    let Some(json) = parse_body(target, body) else {
        return results;
    };
    
    for metric in &target.metrics {
        for item in run_jq(&json, &metric.items_query) {
            // Parse the jq result back to a Value for further processing
            let item_val: Value = serde_json::from_str(&item.to_string()).unwrap_or(Value::Null);
            
            // Extract numeric values using the value query
            for v in run_jq(&item_val, &metric.value_query) {
                let value = v.as_f64().unwrap_or(0.0);
                
                // Always include target name as the first label
                let mut labels = vec![target.name.clone()];
                
                // Add any additional labels defined in the metric
                if let Some(lbls) = &metric.labels {
                    for lbl in lbls {
                        let label_value = extract_label(&item_val, &lbl.query);
                        labels.push(label_value);
                    }
                }
                
                results.push((metric.name.clone(), labels, value));
            }
        }
    }
    
    results
}
