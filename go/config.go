package main

import (
	"fmt"
	"net/http"
	"os"

	"gopkg.in/yaml.v3"
)

type (
	Config struct {
		Targets []Target `yaml:"targets"`
	}

	Target struct {
		Name               string            `yaml:"name"`
		URI                string            `yaml:"uri"`
		Method             string            `yaml:"method"`
		UseBearerTokenFrom string            `yaml:"useBearerTokenFrom"`
		Headers            map[string]string `yaml:"headers"`
		FormParams         map[string]string `yaml:"formParams"`
		PeriodSeconds      int               `yaml:"periodSeconds"`
		Metrics            []MetricConfig    `yaml:"metrics"`
	}

	MetricConfig struct {
		Name       string       `yaml:"name"`
		ItemsQuery string       `yaml:"itemsQuery"`
		ValueQuery string       `yaml:"valueQuery"`
		Labels     []LabelQuery `yaml:"labels"`
	}

	LabelQuery struct {
		Name  string `yaml:"name"`
		Query string `yaml:"query"`
	}
)

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}
	if len(cfg.Targets) == 0 {
		return nil, fmt.Errorf("config has no targets")
	}
	for i := range cfg.Targets {
		if err := cfg.Targets[i].normalize(); err != nil {
			return nil, err
		}
	}
	return &cfg, nil
}

func (t *Target) normalize() error {
	if t.Name == "" {
		return fmt.Errorf("target name is required")
	}
	if t.URI == "" {
		return fmt.Errorf("target %s: uri is required", t.Name)
	}
	if t.Method == "" {
		t.Method = http.MethodGet
	}
	switch t.Method {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete:
	default:
		return fmt.Errorf("target %s: unsupported method %q", t.Name, t.Method)
	}
	if t.PeriodSeconds <= 0 {
		return fmt.Errorf("target %s: periodSeconds must be > 0", t.Name)
	}
	if t.UseBearerTokenFrom != "" && os.Getenv(t.UseBearerTokenFrom) == "" {
		return fmt.Errorf("target %s: bearer token env var %s is not set", t.Name, t.UseBearerTokenFrom)
	}
	if t.Metrics == nil {
		return fmt.Errorf("target %s: metrics is required", t.Name)
	}
	for i := range t.Metrics {
		m := &t.Metrics[i]
		if m.Name == "" {
			return fmt.Errorf("target %s: metric name is required", t.Name)
		}
		if m.ValueQuery == "" {
			return fmt.Errorf("target %s: metric %s: valueQuery is required", t.Name, m.Name)
		}
		if m.ItemsQuery == "" {
			m.ItemsQuery = "."
		}
	}
	return nil
}
