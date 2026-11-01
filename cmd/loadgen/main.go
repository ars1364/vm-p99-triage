// loadgen is an open-loop, constant-rate HTTP load generator that reports
// honest tail latency. It is deliberately open-loop: requests are scheduled at
// a fixed rate regardless of how slow responses are, and each request's latency
// is measured from its SCHEDULED send time, not from when a worker happened to
// pick it up. That corrects "coordinated omission" — the classic closed-loop
// bug where a stalled server hides its own tail because the client stops sending.
//
// Output is a one-line JSON object (p50/p90/p99/p999, success rate, achieved
// rate), so a harness can record it per scenario and diff the tails.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

type result struct {
	URL         string  `json:"url"`
	Label       string  `json:"label"`
	TargetRate  float64 `json:"target_rate_rps"`
	Duration    string  `json:"duration"`
	Sent        int     `json:"sent"`
	OK          int     `json:"ok"`
	Errors      int     `json:"errors"`
	SuccessRate float64 `json:"success_rate"`
	AchievedRPS float64 `json:"achieved_rps"`
	P50ms       float64 `json:"p50_ms"`
	P90ms       float64 `json:"p90_ms"`
	P99ms       float64 `json:"p99_ms"`
	P999ms      float64 `json:"p999_ms"`
	MaxMs       float64 `json:"max_ms"`
}

func main() {
	url := flag.String("url", "http://127.0.0.1:8080/work", "target URL")
	rate := flag.Float64("rate", 200, "requests per second (open loop)")
	dur := flag.Duration("duration", 30*time.Second, "test duration")
	maxInflight := flag.Int("inflight", 512, "max concurrent in-flight requests")
	label := flag.String("label", "", "label for this run (e.g. scenario name)")
	flag.Parse()

	client := &http.Client{Timeout: 20 * time.Second}
	sem := make(chan struct{}, *maxInflight)
	var mu sync.Mutex
	lat := make([]float64, 0, int(*rate)*int(dur.Seconds())+16)
	var ok, errs int
	var wg sync.WaitGroup

	ctx, cancel := context.WithTimeout(context.Background(), *dur)
	defer cancel()

	interval := time.Duration(float64(time.Second) / *rate)
	start := time.Now()
	next := start
	sent := 0
	for {
		now := time.Now()
		if now.After(start.Add(*dur)) {
			break
		}
		if now.Before(next) {
			time.Sleep(next.Sub(now))
		}
		scheduled := next // coordinated-omission anchor
		next = next.Add(interval)
		sent++
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, *url, nil)
			resp, err := client.Do(req)
			elapsed := time.Since(scheduled).Seconds() * 1000.0
			mu.Lock()
			if err != nil {
				errs++
			} else {
				resp.Body.Close()
				if resp.StatusCode == 200 {
					ok++
					lat = append(lat, elapsed)
				} else {
					errs++
				}
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	wall := time.Since(start).Seconds()

	sort.Float64s(lat)
	pct := func(p float64) float64 {
		if len(lat) == 0 {
			return 0
		}
		i := int(p * float64(len(lat)))
		if i >= len(lat) {
			i = len(lat) - 1
		}
		return lat[i]
	}
	r := result{
		URL: *url, Label: *label, TargetRate: *rate, Duration: dur.String(),
		Sent: sent, OK: ok, Errors: errs,
		SuccessRate: float64(ok) / float64(max(sent, 1)),
		AchievedRPS: float64(ok) / wall,
		P50ms:       pct(0.50), P90ms: pct(0.90), P99ms: pct(0.99), P999ms: pct(0.999),
	}
	if len(lat) > 0 {
		r.MaxMs = lat[len(lat)-1]
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "")
	_ = enc.Encode(r)
	fmt.Fprintf(os.Stderr, "[loadgen] %s: sent=%d ok=%d err=%d p99=%.1fms p999=%.1fms rps=%.0f\n",
		*label, sent, ok, errs, r.P99ms, r.P999ms, r.AchievedRPS)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
