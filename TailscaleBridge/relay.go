package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type dialFunc func(context.Context, string, string) (net.Conn, error)

// Only loopback listeners are exposed. Every outbound connection uses tsnet.
// UDP is copied one datagram at a time, never through a stream socketpair.
type relay struct {
	ctx     context.Context
	cancel  context.CancelFunc
	dial    dialFunc
	peer    string
	mu      sync.Mutex
	closed  bool
	sockets map[io.Closer]bool
	wg      sync.WaitGroup
	report  func(error)
}

func newRelay(peer string, dial dialFunc, report func(error)) *relay {
	ctx, cancel := context.WithCancel(context.Background())
	return &relay{ctx: ctx, cancel: cancel, peer: peer, dial: dial, sockets: make(map[io.Closer]bool), report: report}
}
func (r *relay) track(c io.Closer) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		c.Close()
		return false
	}
	r.sockets[c] = true
	return true
}
func (r *relay) release(c io.Closer) { c.Close(); r.mu.Lock(); delete(r.sockets, c); r.mu.Unlock() }
func (r *relay) close() {
	r.cancel()
	r.mu.Lock()
	r.closed = true
	for c := range r.sockets {
		c.Close()
	}
	r.mu.Unlock()
	r.wg.Wait()
}
func (r *relay) failure(err error) {
	if err != nil && r.ctx.Err() == nil {
		r.report(err)
	}
}
func (r *relay) tcp(local string, port int) error {
	l, err := net.Listen("tcp4", local)
	if err != nil {
		return err
	}
	if !r.track(l) {
		return net.ErrClosed
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer r.release(l)
		for {
			c, e := l.Accept()
			if e != nil {
				r.failure(e)
				return
			}
			if !r.track(c) {
				return
			}
			r.wg.Add(1)
			go func() {
				defer r.wg.Done()
				defer r.release(c)
				ctx, cancel := context.WithTimeout(r.ctx, 10*time.Second)
				remote, e := r.dial(ctx, "tcp", net.JoinHostPort(r.peer, fmt.Sprint(port)))
				cancel()
				if e != nil {
					r.failure(fmt.Errorf("TCP %d: %w", port, e))
					return
				}
				if !r.track(remote) {
					return
				}
				defer r.release(remote)
				var closing atomic.Bool
				reportCopyFailure := func(err error) {
					// The other copy loop closes these sockets to unblock us.
					// Suppress only that local-close error, not resets/timeouts.
					if closing.Load() && errors.Is(err, net.ErrClosed) {
						return
					}
					r.failure(err)
				}
				// Preserve half-close: a request writer may close before reading its reply.
				done := make(chan struct{})
				go func() {
					_, e := io.Copy(remote, c)
					if e != nil {
						reportCopyFailure(e)
						closing.Store(true)
						remote.Close()
					} else if h, ok := remote.(interface{ CloseWrite() error }); ok {
						h.CloseWrite()
					} else {
						closing.Store(true)
						remote.Close()
					}
					close(done)
				}()
				_, e = io.Copy(c, remote)
				reportCopyFailure(e)
				closing.Store(true)
				c.Close()
				remote.Close()
				<-done
			}()
		}
	}()
	return nil
}

func (r *relay) udp(local string, port int) error {
	addr, err := net.ResolveUDPAddr("udp4", local)
	if err != nil {
		return err
	}
	l, err := net.ListenUDP("udp4", addr)
	if err != nil {
		return err
	}
	if !r.track(l) {
		return net.ErrClosed
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer r.release(l)
		// One independent tailnet socket per local source preserves ENet/RTP flows.
		var mu sync.Mutex
		flows := map[string]net.Conn{}
		buf := make([]byte, 65535)
		for {
			n, src, e := l.ReadFromUDP(buf)
			if e != nil {
				r.failure(e)
				return
			}
			key := src.String()
			mu.Lock()
			c := flows[key]
			full := len(flows) >= 32
			mu.Unlock()
			if c == nil {
				if full {
					r.failure(fmt.Errorf("UDP %d: flow limit reached", port))
					continue
				}
				ctx, cancel := context.WithTimeout(r.ctx, 10*time.Second)
				c, e = r.dial(ctx, "udp", net.JoinHostPort(r.peer, fmt.Sprint(port)))
				cancel()
				if e != nil {
					// Drop this datagram only; later packets retry the dial.
					r.failure(fmt.Errorf("UDP %d: %w", port, e))
					continue
				}
				if !r.track(c) {
					return
				}
				mu.Lock()
				flows[key] = c
				mu.Unlock()
				r.wg.Add(1)
				go func(c net.Conn, src *net.UDPAddr, key string) {
					defer r.wg.Done()
					defer r.release(c)
					defer func() { mu.Lock(); delete(flows, key); mu.Unlock() }()
					reply := make([]byte, 65535)
					for {
						c.SetReadDeadline(time.Now().Add(60 * time.Second))
						n, e := c.Read(reply)
						if e != nil {
							if ne, ok := e.(net.Error); !ok || !ne.Timeout() {
								r.failure(e)
							}
							return
						}
						if _, e = l.WriteToUDP(reply[:n], src); e != nil {
							r.failure(e)
							return
						}
					}
				}(c, src, key)
			}
			if _, e = c.Write(buf[:n]); e != nil {
				r.failure(e)
			}
		}
	}()
	return nil
}
