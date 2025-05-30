package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/spf13/cobra"
)

func createRootCmd() *cobra.Command {
	var (
		cfgPath    string
		listenAddr string
		logLevel   string
	)
	cmd := &cobra.Command{
		Use:   "json2prom",
		Short: "curl->json->jq->prometheus_metric",
		RunE: func(cmd *cobra.Command, args []string) error {
			level := slog.LevelInfo
			switch logLevel {
			case "debug":
				level = slog.LevelDebug
			case "warn":
				level = slog.LevelWarn
			case "error":
				level = slog.LevelError
			}
			logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))

			ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
			defer stop()

			cfg, err := LoadConfig(cfgPath)
			if err != nil {
				return err
			}

			for _, tgt := range cfg.Targets {
				p, err := NewPoller(tgt, logger)
				if err != nil {
					return err
				}
				go p.Run(ctx)
			}

			// expose Prometheus metrics
			srv := &http.Server{
				Addr:         listenAddr,
				ReadTimeout:  5 * time.Second,
				WriteTimeout: 10 * time.Second,
				Handler:      promhttp.Handler(),
			}
			go func() {
				logger.Info("serving metrics", "addr", listenAddr)
				if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
					logger.Error("http server error", "error", err)
					stop()
				}
			}()

			<-ctx.Done()
			ctxTimeout, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return srv.Shutdown(ctxTimeout)
		},
	}

	cmd.PersistentFlags().StringVar(&cfgPath, "config", "config.yaml", "Path to YAML configuration file")
	cmd.PersistentFlags().StringVar(&listenAddr, "listen", "0.0.0.0:9101", "HTTP listen address for Prometheus metrics endpoint")
	cmd.PersistentFlags().StringVar(&logLevel, "log-level", "info", "Log level (debug, info, warn, error)")

	return cmd
}

func main() {
	if err := createRootCmd().Execute(); err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}
}
