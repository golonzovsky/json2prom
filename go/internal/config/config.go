package config

import (
	"os"

	"gopkg.in/yaml.v3"
)

type (
	Config struct {
		Targets []Target `yaml:"targets"`
	}

	Target struct {
		Name              string            `yaml:"name"`
		URI               string            `yaml:"uri"`
		Method            string            `yaml:"method"`
		IncludeAuthHeader bool              `yaml:"includeAuthHeader"`
		Headers           map[string]string `yaml:"headers"`
		FormParams        map[string]string `yaml:"formParams"`
		PeriodSeconds     int               `yaml:"periodSeconds"`
		Metrics           []MetricConfig    `yaml:"metrics"`
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

func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
