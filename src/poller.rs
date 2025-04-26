use crate::response::process_response;
use crate::types::Target;
use reqwest::Client;
use std::time::Duration;
use tokio::time;

/// Starts a polling loop for the given target.
pub async fn start_poller(target: Target, client: Client) {
    let mut interval = time::interval(Duration::from_secs(target.period_seconds));
    loop {
        interval.tick().await;

        let mut req_builder = client.request(target.method.parse().unwrap(), &target.uri);

        if target.include_auth_header {
            //TODO: token from env
            req_builder = req_builder.header("Authorization", "Bearer TOKEN");
        }

        if let Some(ref hdrs) = target.headers {
            for (k, v) in hdrs {
                req_builder = req_builder.header(k, v);
            }
        }

        if let Some(ref params) = target.form_params {
            req_builder = req_builder.form(params);
        }

        // TODO: parse values and set prometheus metrics
        match req_builder.send().await {
            Ok(resp) => match resp.text().await {
                Ok(body) => process_response(&target, &body),
                Err(e) => eprintln!("[{}] Failed to read body: {}", target.name, e),
            },
            Err(e) => eprintln!("[{}] Request error: {}", target.name, e),
        }
    }
}
