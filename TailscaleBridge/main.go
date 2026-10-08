package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

var state struct {
	sync.Mutex
	server       *tsnet.Server
	relay        *relay
	peer         string
	loginStarted time.Time
}
var lastFailure struct {
	sync.Mutex
	message string
	at      time.Time
}

func remember(err error) {
	if err != nil {
		// Keep the latest failure as history, not proof of current connectivity.
		lastFailure.Lock()
		lastFailure.message = err.Error()
		lastFailure.at = time.Now()
		lastFailure.Unlock()
	}
}
func forget() {
	lastFailure.Lock()
	lastFailure.message = ""
	lastFailure.at = time.Time{}
	lastFailure.Unlock()
}
func result(err error) *C.char {
	if err == nil {
		return nil
	}
	remember(err)
	return C.CString(err.Error())
}

func validPeer(peer string) bool {
	if ip, e := netip.ParseAddr(peer); e == nil {
		return netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip)
	}
	// Require an explicit tailnet FQDN to avoid public DNS/subnet confusion.
	if !strings.HasSuffix(peer, ".ts.net") || len(peer) > 253 {
		return false
	}
	for _, label := range strings.Split(peer, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}

// MTStart starts a persistent userspace node, without VPN entitlements/auth keys.
// It does not choose a PC; login and the PC list work before MTSetPeer.
// Starting an already running node is a no-op.
// Returns NULL on success or a malloc-owned error string (MTFree).
//
//export MTStart
func MTStart(directory *C.char) *C.char {
	state.Lock()
	defer state.Unlock()
	if state.server != nil {
		return nil
	}
	dir := C.GoString(directory)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return result(err)
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return result(err)
	}
	s := &tsnet.Server{Dir: dir, Hostname: "moonlight-ios", Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	if err := s.Start(); err != nil {
		s.Close()
		return result(err)
	}
	state.server = s
	// tsnet already requests a login URL when the saved state needs one.
	state.loginStarted = time.Now()
	forget()
	return nil
}

func closeRelay() {
	if state.relay != nil {
		state.relay.close()
		state.relay = nil
	}
	state.peer = ""
}

// MTSetPeer points the fixed loopback ports at one Sunshine PC. An empty
// peer only closes the relay. Requires MTStart.
//
//export MTSetPeer
func MTSetPeer(peerValue *C.char) *C.char {
	state.Lock()
	defer state.Unlock()
	peer := strings.ToLower(strings.TrimSpace(C.GoString(peerValue)))
	if peer != "" && !validPeer(peer) {
		return result(fmt.Errorf("Enter a Tailscale IP or full .ts.net name"))
	}
	if state.server == nil {
		return result(fmt.Errorf("Tailscale is not running"))
	}
	if peer == state.peer && state.relay != nil {
		return nil
	}
	closeRelay()
	forget()
	if peer == "" {
		return nil
	}
	r := newRelay(peer, state.server.Dial, remember)
	for _, p := range []int{47984, 47989, 48010} {
		if err := r.tcp(fmt.Sprintf("127.0.0.1:%d", p), p); err != nil {
			r.close()
			return result(err)
		}
	}
	for _, p := range []int{47998, 47999, 48000} {
		if err := r.udp(fmt.Sprintf("127.0.0.1:%d", p), p); err != nil {
			r.close()
			return result(err)
		}
	}
	state.relay = r
	state.peer = peer
	return nil
}

//export MTStop
func MTStop() {
	state.Lock()
	defer state.Unlock()
	closeRelay()
	if state.server != nil {
		state.server.Close()
		state.server = nil
	}
}

// MTLogout removes this device's login from the tailnet. The node keeps
// running so the next MTStatus(1) can request a new sign-in URL.
//
//export MTLogout
func MTLogout() *C.char {
	state.Lock()
	defer state.Unlock()
	if state.server == nil {
		return result(fmt.Errorf("Tailscale is not running"))
	}
	lc, err := state.server.LocalClient()
	if err != nil {
		return result(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	closeRelay()
	state.loginStarted = time.Time{}
	return result(lc.Logout(ctx))
}

type peerInfo struct {
	Name   string `json:"name"`
	DNS    string `json:"dns"`
	IP     string `json:"ip"`
	OS     string `json:"os"`
	Online bool   `json:"online"`
	// The PC's private LAN address when Tailscale reaches it directly on the
	// same network; lets the app connect over the LAN instead of the tailnet.
	LAN string `json:"lan,omitempty"`
}

func lanAddress(curAddr string) string {
	if ap, err := netip.ParseAddrPort(curAddr); err == nil && ap.Addr().IsPrivate() {
		return ap.Addr().Unmap().String()
	}
	return ""
}

func firstIP(addrs []netip.Addr) string {
	for _, a := range addrs {
		if a.Is4() {
			return a.String()
		}
	}
	if len(addrs) > 0 {
		return addrs[0].String()
	}
	return ""
}

// MTStatus uses the in-memory LocalAPI, so status does not depend on a loopback
// HTTP listener surviving iOS suspension. Login URLs never enter the log.
// With login != 0, a node that needs login requests a sign-in URL.
//
//export MTStatus
func MTStatus(login C.int) *C.char {
	state.Lock()
	defer state.Unlock()
	output := map[string]any{"state": "Off", "peer": state.peer}
	if state.server != nil {
		lc, err := state.server.LocalClient()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err == nil {
			st, e := lc.Status(ctx)
			err = e
			if err == nil {
				output["state"] = st.BackendState
				output["authURL"] = st.AuthURL
				if st.CurrentTailnet != nil {
					output["tailnet"] = st.CurrentTailnet.Name
				}
				if st.Self != nil {
					output["selfIP"] = firstIP(st.Self.TailscaleIPs)
					if u, ok := st.User[st.Self.UserID]; ok {
						output["user"] = u.LoginName
					}
				}
				peers := []peerInfo{}
				for _, p := range st.Peer {
					ip := firstIP(p.TailscaleIPs)
					if ip == "" {
						continue
					}
					name := p.HostName
					if dns := strings.Split(p.DNSName, "."); dns[0] != "" {
						name = dns[0]
					}
					peers = append(peers, peerInfo{Name: name, DNS: strings.TrimSuffix(p.DNSName, "."), IP: ip, OS: p.OS, Online: p.Online, LAN: lanAddress(p.CurAddr)})
				}
				sort.Slice(peers, func(i, j int) bool {
					if peers[i].Online != peers[j].Online {
						return peers[i].Online
					}
					return strings.ToLower(peers[i].Name) < strings.ToLower(peers[j].Name)
				})
				output["peers"] = peers
				// The URL arrives asynchronously; avoid restarting the login on
				// every poll while it is being prepared.
				if login != 0 && st.BackendState == "NeedsLogin" && st.AuthURL == "" && time.Since(state.loginStarted) > 15*time.Second {
					state.loginStarted = time.Now()
					err = lc.StartLoginInteractive(ctx)
				}
			}
		}
		if err != nil {
			output["error"] = err.Error()
		}
	}
	lastFailure.Lock()
	output["transportError"] = lastFailure.message
	if !lastFailure.at.IsZero() {
		output["transportErrorTime"] = lastFailure.at.Unix()
	}
	lastFailure.Unlock()
	b, _ := json.Marshal(output)
	return C.CString(string(b))
}

// MTProbe checks the chosen PC in two steps so failures can be explained:
// a Tailscale ping (is the PC reachable on the tailnet at all?) and a TCP
// connection to Sunshine's HTTP port (is Sunshine reachable through it?).
// Returns malloc-owned JSON (MTFree).
//
//export MTProbe
func MTProbe(peerValue *C.char) *C.char {
	peer := strings.ToLower(strings.TrimSpace(C.GoString(peerValue)))
	state.Lock()
	s := state.server
	state.Unlock()
	output := map[string]any{"ok": false}
	finish := func() *C.char {
		b, _ := json.Marshal(output)
		return C.CString(string(b))
	}
	if s == nil {
		output["stage"] = "node"
		output["error"] = "Tailscale is not running"
		return finish()
	}
	lc, err := s.LocalClient()
	if err != nil {
		output["stage"] = "node"
		output["error"] = err.Error()
		return finish()
	}

	ip, err := netip.ParseAddr(peer)
	if err != nil {
		// Find the tailnet IP of a MagicDNS name
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		st, e := lc.Status(ctx)
		cancel()
		if e == nil {
			for _, p := range st.Peer {
				if strings.EqualFold(strings.TrimSuffix(p.DNSName, "."), peer) && len(p.TailscaleIPs) > 0 {
					ip = p.TailscaleIPs[0]
				}
			}
		}
	}
	if ip.IsValid() {
		// The first ping also sets up the path (direct or DERP relay).
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		res, e := lc.Ping(ctx, ip, tailcfg.PingDisco)
		cancel()
		if e == nil && res.Err != "" {
			e = fmt.Errorf("%s", res.Err)
		}
		if e != nil {
			output["stage"] = "ping"
			output["error"] = e.Error()
			return finish()
		}
		output["latencyMs"] = int(res.LatencySeconds * 1000)
		if res.Endpoint != "" {
			output["path"] = "direct"
		} else if res.DERPRegionCode != "" {
			output["path"] = "relay " + res.DERPRegionCode
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	c, err := s.Dial(ctx, "tcp", net.JoinHostPort(peer, "47989"))
	if err != nil {
		output["stage"] = "sunshine"
		output["error"] = err.Error()
		return finish()
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	if _, err = c.Write([]byte("GET /serverinfo HTTP/1.0\r\nHost: " + peer + "\r\n\r\n")); err == nil {
		reply := make([]byte, 5)
		_, err = io.ReadFull(c, reply)
		if err == nil && string(reply) != "HTTP/" {
			err = fmt.Errorf("port 47989 did not answer like Sunshine")
		}
	}
	if err != nil {
		output["stage"] = "sunshine"
		output["error"] = err.Error()
		return finish()
	}
	output["ok"] = true
	return finish()
}

// MTNetworkChanged tells the node that Wi-Fi/cellular changed, so it rebinds
// its sockets and finds a new path right away instead of waiting to notice.
//
//export MTNetworkChanged
func MTNetworkChanged() {
	state.Lock()
	s := state.server
	state.Unlock()
	if s == nil {
		return
	}
	go func() {
		lc, err := s.LocalClient()
		if err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		remember(lc.DebugAction(ctx, "rebind"))
		remember(lc.DebugAction(ctx, "restun"))
	}()
}

//export MTFree
func MTFree(p unsafe.Pointer) { C.free(p) }
func main()                   {}
