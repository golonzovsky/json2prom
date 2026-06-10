package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func writeConfig(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadConfigDefaults(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t, `
targets:
  - name: t1
    uri: http://example.com
    periodSeconds: 60
    metrics:
      - name: m1
        valueQuery: .val
`))
	if err != nil {
		t.Fatal(err)
	}
	tgt := cfg.Targets[0]
	if tgt.Method != http.MethodGet {
		t.Errorf("default method = %q, want GET", tgt.Method)
	}
	if got := tgt.Metrics[0].ItemsQuery; got != "." {
		t.Errorf("default itemsQuery = %q, want .", got)
	}
}

func TestLoadConfigValidation(t *testing.T) {
	for name, tc := range map[string]struct {
		yaml    string
		wantErr string
	}{
		"zero period": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    periodSeconds: 0
    metrics: []
`,
			wantErr: "periodSeconds must be > 0",
		},
		"bad method": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    method: PATCH
    periodSeconds: 60
    metrics: []
`,
			wantErr: "unsupported method",
		},
		"missing bearer env": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    useBearerTokenFrom: JSON2PROM_TEST_MISSING_TOKEN
    periodSeconds: 60
    metrics: []
`,
			wantErr: "bearer token env var JSON2PROM_TEST_MISSING_TOKEN is not set",
		},
		"no targets": {
			yaml: `
targets: []
`,
			wantErr: "config has no targets",
		},
		"missing name": {
			yaml: `
targets:
  - uri: http://example.com
    periodSeconds: 60
    metrics: []
`,
			wantErr: "target name is required",
		},
		"missing uri": {
			yaml: `
targets:
  - name: t1
    periodSeconds: 60
    metrics: []
`,
			wantErr: "uri is required",
		},
		"missing metrics": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    periodSeconds: 60
`,
			wantErr: "metrics is required",
		},
		"missing metric name": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    periodSeconds: 60
    metrics:
      - valueQuery: .val
`,
			wantErr: "metric name is required",
		},
		"missing valueQuery": {
			yaml: `
targets:
  - name: t1
    uri: http://example.com
    periodSeconds: 60
    metrics:
      - name: m1
`,
			wantErr: "valueQuery is required",
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := LoadConfig(writeConfig(t, tc.yaml))
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("err = %v, want containing %q", err, tc.wantErr)
			}
		})
	}
}

func TestLoadConfigBearerEnvSet(t *testing.T) {
	t.Setenv("JSON2PROM_TEST_TOKEN", "secret")
	_, err := LoadConfig(writeConfig(t, `
targets:
  - name: t1
    uri: http://example.com
    useBearerTokenFrom: JSON2PROM_TEST_TOKEN
    periodSeconds: 60
    metrics: []
`))
	if err != nil {
		t.Fatal(err)
	}
}

func newTestPoller(t *testing.T, tgt Target) (*Poller, *prometheus.Registry) {
	t.Helper()
	if err := tgt.normalize(); err != nil {
		t.Fatal(err)
	}
	reg := prometheus.NewRegistry()
	p, err := NewPoller(tgt, reg, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	return p, reg
}

func gatherSeries(t *testing.T, reg *prometheus.Registry, metric string) []*dto.Metric {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range families {
		if f.GetName() == metric {
			return f.GetMetric()
		}
	}
	return nil
}

func labels(m *dto.Metric) map[string]string {
	out := map[string]string{}
	for _, l := range m.GetLabel() {
		out[l.GetName()] = l.GetValue()
	}
	return out
}

func parseJSON(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestEvaluateItemsAndLabels(t *testing.T) {
	p, reg := newTestPoller(t, Target{
		Name:          "my-target",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "test_metric",
			ItemsQuery: ".items[]",
			ValueQuery: ".val",
			Labels: []LabelQuery{
				{Name: "str_label", Query: ".name"},
				{Name: "num_label", Query: ".id"},
				{Name: "null_label", Query: ".nope"},
				{Name: "noresult_label", Query: "empty"},
			},
		}},
	})

	p.evaluate(parseJSON(t, `{"items": [
		{"name": "a", "id": 7, "val": 1.5},
		{"name": "b", "id": 8, "val": 42}
	]}`))

	series := gatherSeries(t, reg, "test_metric")
	if len(series) != 2 {
		t.Fatalf("got %d series, want 2", len(series))
	}
	byName := map[string]*dto.Metric{}
	for _, s := range series {
		byName[labels(s)["str_label"]] = s
	}

	a := byName["a"]
	if a == nil {
		t.Fatal("series with str_label=a not found")
	}
	if got := a.GetGauge().GetValue(); got != 1.5 {
		t.Errorf("value = %v, want 1.5", got)
	}
	la := labels(a)
	if la["target"] != "my-target" {
		t.Errorf("target label = %q, want my-target", la["target"])
	}
	if la["num_label"] != "7" {
		t.Errorf("num_label = %q, want 7 (JSON text)", la["num_label"])
	}
	if la["null_label"] != "null" {
		t.Errorf("null_label = %q, want null (JSON text)", la["null_label"])
	}
	if la["noresult_label"] != "" {
		t.Errorf("noresult_label = %q, want empty", la["noresult_label"])
	}
	if got := byName["b"].GetGauge().GetValue(); got != 42 {
		t.Errorf("value = %v, want 42", got)
	}
}

func TestEvaluateTargetIsFirstLabel(t *testing.T) {
	p, reg := newTestPoller(t, Target{
		Name:          "tgt",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "ordered_metric",
			ValueQuery: ".v",
			Labels:     []LabelQuery{{Name: "aaa", Query: ".x"}},
		}},
	})
	p.evaluate(parseJSON(t, `{"v": 1, "x": "y"}`))

	series := gatherSeries(t, reg, "ordered_metric")
	if len(series) != 1 {
		t.Fatalf("got %d series, want 1", len(series))
	}
	if got := labels(series[0])["target"]; got != "tgt" {
		t.Errorf("target label = %q, want tgt", got)
	}
}

func TestEvaluateBoolValues(t *testing.T) {
	p, reg := newTestPoller(t, Target{
		Name:          "t",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "bool_metric",
			ItemsQuery: ".[]",
			ValueQuery: ".up",
			Labels:     []LabelQuery{{Name: "id", Query: ".id"}},
		}},
	})
	p.evaluate(parseJSON(t, `[{"id": "x", "up": true}, {"id": "y", "up": false}]`))

	want := map[string]float64{"x": 1, "y": 0}
	for _, s := range gatherSeries(t, reg, "bool_metric") {
		id := labels(s)["id"]
		if got := s.GetGauge().GetValue(); got != want[id] {
			t.Errorf("id=%s value = %v, want %v", id, got, want[id])
		}
		delete(want, id)
	}
	if len(want) != 0 {
		t.Errorf("missing series for %v", want)
	}
}

func TestEvaluateSkipsNonNumeric(t *testing.T) {
	p, reg := newTestPoller(t, Target{
		Name:          "t",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "skip_metric",
			ItemsQuery: ".[]",
			ValueQuery: ".val",
			Labels:     []LabelQuery{{Name: "id", Query: ".id"}},
		}},
	})
	p.evaluate(parseJSON(t, `[
		{"id": "str", "val": "not-a-number"},
		{"id": "null", "val": null},
		{"id": "absent"},
		{"id": "ok", "val": 3}
	]`))

	series := gatherSeries(t, reg, "skip_metric")
	if len(series) != 1 {
		t.Fatalf("got %d series, want 1 (only numeric item)", len(series))
	}
	if got := labels(series[0])["id"]; got != "ok" {
		t.Errorf("series id = %q, want ok", got)
	}
	if got := series[0].GetGauge().GetValue(); got != 3 {
		t.Errorf("value = %v, want 3", got)
	}
}

func TestNewPollerRejectsUncompilableQuery(t *testing.T) {
	tgt := Target{
		Name:          "t",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "bad_metric",
			ValueQuery: "foo(.)",
		}},
	}
	if err := tgt.normalize(); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPoller(tgt, prometheus.NewRegistry(), slog.New(slog.DiscardHandler)); err == nil {
		t.Error("expected compile error for undefined function, got nil")
	}
}

func TestEvaluateResetsStaleSeries(t *testing.T) {
	p, reg := newTestPoller(t, Target{
		Name:          "t",
		URI:           "http://example.com",
		PeriodSeconds: 60,
		Metrics: []MetricConfig{{
			Name:       "reset_metric",
			ItemsQuery: ".[]",
			ValueQuery: ".val",
			Labels:     []LabelQuery{{Name: "id", Query: ".id"}},
		}},
	})

	p.evaluate(parseJSON(t, `[{"id": "old", "val": 1}, {"id": "kept", "val": 2}]`))
	p.evaluate(parseJSON(t, `[{"id": "kept", "val": 5}]`))

	series := gatherSeries(t, reg, "reset_metric")
	if len(series) != 1 {
		t.Fatalf("got %d series after reset, want 1", len(series))
	}
	if got := labels(series[0])["id"]; got != "kept" {
		t.Errorf("series id = %q, want kept", got)
	}
	if got := series[0].GetGauge().GetValue(); got != 5 {
		t.Errorf("value = %v, want 5", got)
	}
}
