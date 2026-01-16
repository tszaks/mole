package main

import (
	"context"
	"os"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/net"
)

func (c *Collector) collectNetwork(now time.Time) ([]NetworkStatus, error) {
	stats, err := net.IOCounters(true)
	if err != nil {
		return nil, err
	}

	// Map interface IPs.
	ifAddrs := getInterfaceIPs()

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for _, s := range stats {
			c.prevNet[s.Name] = s
		}
		return nil, nil
	}

	elapsed := now.Sub(c.lastNetAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	var result []NetworkStatus
	for _, cur := range stats {
		if isNoiseInterface(cur.Name) {
			continue
		}
		prev, ok := c.prevNet[cur.Name]
		if !ok {
			continue
		}
		rx := float64(cur.BytesRecv-prev.BytesRecv) / 1024.0 / 1024.0 / elapsed
		tx := float64(cur.BytesSent-prev.BytesSent) / 1024.0 / 1024.0 / elapsed
		if rx < 0 {
			rx = 0
		}
		if tx < 0 {
			tx = 0
		}
		result = append(result, NetworkStatus{
			Name:      cur.Name,
			RxRateMBs: rx,
			TxRateMBs: tx,
			IP:        ifAddrs[cur.Name],
		})
	}

	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].RxRateMBs+result[i].TxRateMBs > result[j].RxRateMBs+result[j].TxRateMBs
	})
	if len(result) > 3 {
		result = result[:3]
	}

	var totalRx, totalTx float64
	for _, r := range result {
		totalRx += r.RxRateMBs
		totalTx += r.TxRateMBs
	}

	// Update history using the global/aggregated stats
	c.rxHistoryBuf.Add(totalRx)
	c.txHistoryBuf.Add(totalTx)

	return result, nil
}

// Rewriting slightly more of the file to inject history update logic correctly inside the loop.
// The previous "tail" logic for totalRx history was actually not what I wrote in the *previous* step
// (Wait, did the `pull` bring in my changes? No, I implemented them, then did `git reset` then `git pull`.
// The `git pull` brought in the changes from `dev`.
// In `dev` (which I pulled), the code at the bottom of `collectNetwork` (lines 73-86 in View)
// seems to be appending to `c.netHistory.RxHistory`.
// So the merged code uses a GLOBAL history in `MetricsSnapshot` (or `Collector`?)
// Let's check `metrics.go` again.
// In the pulled `metrics.go` (before my generic change):
// type NetworkHistory struct { RxHistory []float64 ... }
// type Collector struct { ... netHistory NetworkHistory ... }
// So the user's merged code uses a SINGLE global history struct, not a map per interface.
// This simplifies things! It aggregates ALL traffic history?
// Or does it just append the totals?
// Line 73-77 calculates `totalRx`.
// Line 78 appends `totalRx` to `c.netHistory.RxHistory`.
// Yes, it tracks GLOBAL network usage.
// So I should adapt my RingBuffer to replace `NetworkHistory` struct usage.

// I will replace `collectNetwork` to use the new `map[string][2]*RingBuffer`?
// User asked to "optimize". Global history is easier for the UI ("Total Down/Up").
// Per-interface history is more detailed but if UI only shows one sparkline, Global is better.
// The user said "responsive width... reference Proxy System".
// And "generic history structure".
// If I use RingBuffer, I should probably stick to the GLOBAL history design if that's what `dev` has,
// OR change `Collector` to use `RingBuffer` for that global history.
//
// Let's look at `metrics.go` again (my previous edit).
// I changed `netHistory` to `map[string][2]*RingBuffer`.
// This contradicts the `dev` branch's `NetworkHistory` (global).
// I should probably revert to a SINGLE `RingBuffer` pair for global history if the UI expects global.
// Usage in `view.go` (which I haven't read fully yet after pull) will tell me.
// If `view.go` uses `m.NetworkHistory.RxHistory`, then it expects global.
// Let's check `view.go` first before editing `metrics_network.go`.


func getInterfaceIPs() map[string]string {
	result := make(map[string]string)
	ifaces, err := net.Interfaces()
	if err != nil {
		return result
	}
	for _, iface := range ifaces {
		for _, addr := range iface.Addrs {
			// IPv4 only.
			if strings.Contains(addr.Addr, ".") && !strings.HasPrefix(addr.Addr, "127.") {
				ip := strings.Split(addr.Addr, "/")[0]
				result[iface.Name] = ip
				break
			}
		}
	}
	return result
}

func isNoiseInterface(name string) bool {
	lower := strings.ToLower(name)
	noiseList := []string{"lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"}
	for _, prefix := range noiseList {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectProxy() ProxyStatus {
	// Check environment variables first.
	for _, env := range []string{"https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"} {
		if val := os.Getenv(env); val != "" {
			proxyType := "HTTP"
			if strings.HasPrefix(val, "socks") {
				proxyType = "SOCKS"
			}
			// Extract host.
			host := val
			if strings.Contains(host, "://") {
				host = strings.SplitN(host, "://", 2)[1]
			}
			if idx := strings.Index(host, "@"); idx >= 0 {
				host = host[idx+1:]
			}
			return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
		}
	}

	// macOS: check system proxy via scutil.
	if runtime.GOOS == "darwin" {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel()
		out, err := runCmd(ctx, "scutil", "--proxy")
		if err == nil {
			if strings.Contains(out, "HTTPEnable : 1") || strings.Contains(out, "HTTPSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "System", Host: "System Proxy"}
			}
			if strings.Contains(out, "SOCKSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "SOCKS", Host: "System Proxy"}
			}
		}
	}

	return ProxyStatus{Enabled: false}
}
