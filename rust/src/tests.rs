#[cfg(test)]
mod test_utils {
    use crate::config::load_config;
    use crate::response::extract_metrics;
    use crate::config::Target;

    fn create_test_target(xml_mode: bool) -> Target {
        let config_file = if xml_mode {
            "/Users/ax/project/rust/grafana-to-go/rust/evo-xml-example.yaml"
        } else {
            "/Users/ax/project/rust/grafana-to-go/rust/evo.yaml"
        };
        
        // Load the first target from the config file
        let config = load_config(config_file).expect("Failed to load config file");
        let mut target = config.targets.into_iter().next().expect("No targets in config file");
        
        // Rename the target for test isolation
        if xml_mode {
            target.name = "test-evo-enge-xml".to_string();
        } else {
            target.name = "test-evo-enge".to_string();
        }
        
        target
    }

    const JSON_RESPONSE: &str = r#"{"id":"6c13f942-01dc-4141-8b0b-328291cc97ca","name":"EVO Zurich Enge","max_capacity":90,"current":35,"percentageUsed":38.88888888888889}"#;

    const XML_RESPONSE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<response>
    <id>6c13f942-01dc-4141-8b0b-328291cc97ca</id>
    <name>EVO Zurich Enge</name>
    <max_capacity>90</max_capacity>
    <current>35</current>
    <percentageUsed>38.88888888888889</percentageUsed>
</response>"#;

    #[test]
    fn test_json_mode() {
        let target = create_test_target(false);
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
    fn test_xml_mode() {
        let target = create_test_target(true);
        let metrics = extract_metrics(&target, XML_RESPONSE);

        println!("XML metrics: {:?}", metrics);
        assert_eq!(metrics.len(), 2, "Should extract 2 metrics");

        // Sort metrics by name to ensure consistent order for testing
        let mut sorted_metrics = metrics;
        sorted_metrics.sort_by(|a, b| a.0.cmp(&b.0));

        // Check capacity metric
        let (name, labels, value) = &sorted_metrics[0];
        assert_eq!(name, "evo_capacity");
        assert_eq!(labels.len(), 3);
        assert_eq!(labels[0], "test-evo-enge-xml");
        assert_eq!(labels[1], "EVO Zurich Enge");
        // XML mode converts numbers to strings with decimal point
        assert_eq!(labels[2], "90.0");
        assert!((*value - 35.0).abs() < 0.0001, "Expected value: 35.0, got: {}", value);

        // Check percentage metric
        let (name, labels, value) = &sorted_metrics[1];
        assert_eq!(name, "evo_percentage");
        assert_eq!(labels.len(), 3);
        assert_eq!(labels[0], "test-evo-enge-xml");
        assert_eq!(labels[1], "EVO Zurich Enge");
        // XML mode converts numbers to strings with decimal point
        assert_eq!(labels[2], "90.0");
        assert!((*value - 38.88888888888889).abs() < 0.0001, 
                "Expected value: 38.88888888888889, got: {}", value);
    }

    #[test]
    fn test_xml_fallback_to_json() {
        // Create an XML mode target but feed it JSON data
        // Use a new JSON_RESPONSE with simple numbers to avoid floating point precision issues
        let simple_json = r#"{"id":"6c13f942-01dc-4141-8b0b-328291cc97ca","name":"EVO Zurich Enge","max_capacity":90,"current":35,"percentageUsed":39}"#;
        let target = create_test_target(true);
        let metrics = extract_metrics(&target, simple_json);

        println!("JSON fallback metrics: {:?}", metrics);
        assert_eq!(metrics.len(), 2, "Should extract 2 metrics even with XML mode and JSON data");
        
        // Sort metrics by name to ensure consistent order for testing
        let mut sorted_metrics = metrics;
        sorted_metrics.sort_by(|a, b| a.0.cmp(&b.0));

        // Verify at least one metric has expected values
        if !sorted_metrics.is_empty() {
            let (name, labels, value) = &sorted_metrics[0];
            assert_eq!(name, "evo_capacity");
            assert!(labels.len() > 1);
            assert!((*value - 35.0).abs() < 0.0001 || (*value - 39.0).abs() < 0.0001,
                    "Expected value close to 35.0 or 39.0, got: {}", value);
        }
    }

    #[test]
    fn test_invalid_input() {
        let target = create_test_target(false);
        let invalid_data = "this is not valid JSON";
        let metrics = extract_metrics(&target, invalid_data);

        assert_eq!(metrics.len(), 0, "Should return empty metrics for invalid data");

        let target = create_test_target(true);
        let metrics = extract_metrics(&target, invalid_data);

        assert_eq!(metrics.len(), 0, "Should return empty metrics for invalid XML data");
    }
}