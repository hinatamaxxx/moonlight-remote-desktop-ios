package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// HTTP servers may finish the response and close while the client keeps its
// request side open. Relay cleanup must not turn that successful EOF into an error.
func TestTCPServerCloseDoesNotReportFailure(t *testing.T) {
	var failures atomic.Int32
	r := newRelay("test", func(ctx context.Context, n, a string) (net.Conn, error) {
		remote, server := net.Pipe()
		go func() {
			defer server.Close()
			server.Write([]byte("HTTP/1.0 200 OK\r\n\r\nreply"))
		}()
		return remote, nil
	}, func(err error) { failures.Add(1) })
	defer r.close()
	if err := r.tcp("127.0.0.1:0", 47989); err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp4", listenerAddress(r, false))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	b, err := io.ReadAll(c)
	if err != nil || string(b) != "HTTP/1.0 200 OK\r\n\r\nreply" {
		t.Fatalf("%q %v", b, err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		r.mu.Lock()
		remaining := len(r.sockets)
		r.mu.Unlock()
		if remaining == 1 {
			break
		} // Only listener remains; both copy loops exited.
		if time.Now().After(deadline) {
			t.Fatal("connection cleanup blocked")
		}
		time.Sleep(time.Millisecond)
	}
	if got := failures.Load(); got != 0 {
		t.Fatalf("successful response reported %d errors", got)
	}
}

func TestTCPDialFailureIsReported(t *testing.T) {
	want := errors.New("unreachable test peer")
	reported := make(chan error, 1)
	r := newRelay("test", func(context.Context, string, string) (net.Conn, error) {
		return nil, want
	}, func(err error) { reported <- err })
	defer r.close()
	if err := r.tcp("127.0.0.1:0", 47989); err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp4", listenerAddress(r, false))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	select {
	case err := <-reported:
		if !errors.Is(err, want) {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("dial failure was hidden")
	}
}

func listenerAddress(r *relay, udp bool) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	for s := range r.sockets {
		if udp {
			if c, ok := s.(*net.UDPConn); ok {
				return c.LocalAddr().String()
			}
		} else {
			if l, ok := s.(net.Listener); ok {
				return l.Addr().String()
			}
		}
	}
	panic("listener not found")
}
func TestTCPHalfClose(t *testing.T) {
	server, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		c, e := server.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		b, _ := io.ReadAll(c)
		c.Write(append([]byte("reply:"), b...))
	}()
	r := newRelay("test", func(ctx context.Context, n, a string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, n, server.Addr().String())
	}, func(error) {})
	defer r.close()
	if e := r.tcp("127.0.0.1:0", 47989); e != nil {
		t.Fatal(e)
	}
	c, e := net.Dial("tcp4", listenerAddress(r, false))
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	c.Write([]byte("request"))
	c.(*net.TCPConn).CloseWrite()
	b, e := io.ReadAll(c)
	if e != nil || string(b) != "reply:request" {
		t.Fatalf("%q %v", b, e)
	}
}
func TestUDPDatagramsAndIndependentClients(t *testing.T) {
	sizes := []int{0, 1, 17, 1024, 8192}
	// Darwin limits local UDP sends to 9216 bytes by default. Keep the
	// large-datagram check on Linux/other hosts without changing kernel settings.
	if runtime.GOOS != "darwin" && runtime.GOOS != "ios" {
		sizes = append(sizes, 65000)
	}
	server, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	go func() {
		b := make([]byte, 65535)
		for {
			n, a, e := server.ReadFromUDP(b)
			if e != nil {
				return
			}
			server.WriteToUDP(b[:n], a)
		}
	}()
	r := newRelay("test", func(ctx context.Context, n, a string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, n, server.LocalAddr().String())
	}, func(error) {})
	defer r.close()
	if e = r.udp("127.0.0.1:0", 47998); e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	for id := 0; id < 2; id++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			c, e := net.Dial("udp4", listenerAddress(r, true))
			if e != nil {
				t.Error(e)
				return
			}
			defer c.Close()
			c.SetDeadline(time.Now().Add(5 * time.Second))
			for _, size := range sizes {
				b := bytes.Repeat([]byte{byte(id + 1)}, size)
				if _, e = c.Write(b); e != nil {
					t.Error(e)
					return
				}
				reply := make([]byte, 65535)
				n, e := c.Read(reply)
				if e != nil || !bytes.Equal(b, reply[:n]) {
					t.Errorf("client %d size %d received %d: %v", id, size, n, e)
					return
				}
			}
		}(id)
	}
	wg.Wait()
}
func TestStopCancelsDialAndReleasesPort(t *testing.T) {
	started := make(chan struct{})
	r := newRelay("test", func(ctx context.Context, n, a string) (net.Conn, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}, func(error) {})
	if e := r.tcp("127.0.0.1:0", 47989); e != nil {
		t.Fatal(e)
	}
	addr := listenerAddress(r, false)
	c, e := net.Dial("tcp4", addr)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("dial not started")
	}
	done := make(chan struct{})
	go func() { r.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("stop blocked")
	}
	l, e := net.Listen("tcp4", addr)
	if e != nil {
		t.Fatal(e)
	}
	l.Close()
}
func TestPeerValidation(t *testing.T) {
	for _, s := range []string{"100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1", "pc.example.ts.net"} {
		if !validPeer(s) {
			t.Errorf("rejected %s", s)
		}
	}
	for _, s := range []string{"127.0.0.1", "192.168.1.1", "100.128.0.1", "example.com", "pc.ts.net:443", "https://pc.ts.net", "-pc.ts.net", "pc..ts.net", ""} {
		if validPeer(s) {
			t.Errorf("accepted %s", s)
		}
	}
}
