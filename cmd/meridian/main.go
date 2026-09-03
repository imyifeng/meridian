// Command meridian runs the Meridian server: a single static binary serving
// the HTTP JSON API backed by SQLite.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/imyifeng/meridian/internal/api"
	"github.com/imyifeng/meridian/internal/store"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dataDir := flag.String("data", "data", "data directory holding meridian.db")
	flag.Parse()

	if err := os.MkdirAll(*dataDir, 0o755); err != nil {
		log.Fatalf("create data dir: %v", err)
	}
	st, err := store.Open(filepath.Join(*dataDir, "meridian.db"))
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer st.Close()

	srv := &http.Server{
		Addr:    *addr,
		Handler: api.NewHandler(st),
	}

	done := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
		close(done)
	}()

	log.Printf("meridian listening on %s (data: %s)", *addr, *dataDir)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serve: %v", err)
	}
	<-done
}
