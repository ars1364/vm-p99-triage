// cpuwork is a tiny HTTP service that burns a FIXED, deterministic amount of
// work per request, so a latency experiment's P99 moves only with the
// environment (CPU steal, cgroup throttling, NUMA placement) — not the app.
//
// Each GET /work does, with fixed cost:
//   - -work  rounds of SHA-256 over a small buffer  (pure CPU / cache-resident)
//   - -reads strided reads across a large -mem-mb buffer (RAM-bound; this is
//     what makes NUMA placement visible — remote memory costs more per read)
// GOMAXPROCS defaults to the usable CPUs, so concurrency spreads across vCPUs
// and hits a cgroup CPU quota when one is imposed.
package main

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"log"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	work := flag.Int("work", 800, "SHA-256 rounds per request (CPU cost)")
	memMB := flag.Int("mem-mb", 256, "size of the RAM-bound buffer in MiB (0 disables)")
	reads := flag.Int("reads", 60000, "strided cache-line reads across the buffer per request (RAM cost)")
	flag.Parse()

	var served uint64
	small := make([]byte, 1024)
	// Large buffer, touched once so pages are faulted in. Strided reads at a
	// cache-line stride defeat the cache and force real memory traffic.
	var big []byte
	if *memMB > 0 {
		big = make([]byte, *memMB*1024*1024)
		for i := range big {
			big[i] = byte(i)
		}
	}
	const stride = 64

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "ok gomaxprocs=%d mem_mb=%d reads=%d work=%d\n", runtime.GOMAXPROCS(0), *memMB, *reads, *work)
	})
	http.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		// RAM-bound phase
		var acc uint64
		if len(big) > 0 {
			idx := uint64(atomic.AddUint64(&served, 1)) * 2654435761 // spread start points
			mask := uint64(len(big) - 1)
			// len(big) isn't a power of two; use modulo on a prime-ish step
			step := uint64(stride)
			pos := idx % uint64(len(big))
			for i := 0; i < *reads; i++ {
				acc += uint64(big[pos])
				pos += step * 97
				if pos >= uint64(len(big)) {
					pos %= uint64(len(big))
				}
				_ = mask
			}
		}
		// CPU / cache-resident phase
		h := sha256.New()
		var sum [32]byte
		copy(sum[:], small)
		for i := 0; i < *work; i++ {
			h.Reset()
			h.Write(sum[:])
			h.Write(small)
			h.Sum(sum[:0])
		}
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "%x %d\n", sum[:6], acc&0xff)
	})

	log.Printf("cpuwork: %s work=%d reads=%d mem=%dMiB GOMAXPROCS=%d", *addr, *work, *reads, *memMB, runtime.GOMAXPROCS(0))
	log.Fatal((&http.Server{Addr: *addr, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
}
