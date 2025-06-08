#[cfg(test)]
mod test_utils {
    use crate::config::Target;
    use crate::config::load_config;
    use crate::response::extract_metrics;

    fn create_test_target() -> Target {
        let config_file = "evo.yaml";

        // Load the first target from the config file
        let config = load_config(config_file).expect("Failed to load config file");
        let mut target = config
            .targets
            .into_iter()
            .next()
            .expect("No targets in config file");

        target.name = "test-evo-enge".to_string();

        target
    }

    const JSON_RESPONSE: &str = r#"{"id":"6c13f942-01dc-4141-8b0b-328291cc97ca","name":"EVO Zurich Enge","max_capacity":90,"current":35,"percentageUsed":38.88888888888889}"#;

    #[test]
    fn test_json_mode() {
        let target = create_test_target();
        let metrics = extract_metrics(&target, JSON_RESPONSE);

        assert_eq!(metrics.len(), 2, "Should extract 2 metrics");

        // Sort metrics by name to ensure consistent order for testing
        let mut sorted_metrics = metrics;
        sorted_metrics.sort_by(|a, b| a.0.cmp(&b.0));

        // Check capacity metric
        let (name, labels, value) = &sorted_metrics[0];
        assert_eq!(name, "evo_capacity");
        assert_eq!(labels.len(), 3);
        assert_eq!(labels[0], "test-evo-enge");
        assert_eq!(labels[1], "EVO Zurich Enge");
        assert_eq!(labels[2], "90");
        assert_eq!(*value, 35.0);

        // Check percentage metric
        let (name, labels, value) = &sorted_metrics[1];
        assert_eq!(name, "evo_percentage");
        assert_eq!(labels.len(), 3);
        assert_eq!(labels[0], "test-evo-enge");
        assert_eq!(labels[1], "EVO Zurich Enge");
        assert_eq!(labels[2], "90");
        assert_eq!(*value, 38.88888888888889);
    }

    #[test]
    fn test_invalid_input() {
        let target = create_test_target();
        let invalid_data = "this is not valid JSON";
        let metrics = extract_metrics(&target, invalid_data);

        assert_eq!(
            metrics.len(),
            0,
            "Should return empty metrics for invalid data"
        );

        let target = create_test_target();
        let metrics = extract_metrics(&target, invalid_data);

        assert_eq!(
            metrics.len(),
            0,
            "Should return empty metrics for invalid XML data"
        );
    }
}

