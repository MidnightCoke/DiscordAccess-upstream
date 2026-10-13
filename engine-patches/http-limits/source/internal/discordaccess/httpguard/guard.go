// Package httpguard bounds pending HTTP authentication without limiting bodies
// or authenticated tunnels. DiscordAccess additions, MIT license.
package httpguard

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

var (
	ErrHeaderTooLarge = errors.New("http request headers exceed the limit")
	ErrCapacity = errors.New("too many pending HTTP handshakes")
)

// Reader counts the request line and MIME headers before the HTTP parser can
// allocate them. Bytes after the empty line are returned without restriction.
// A single Reader and bufio.Reader must be retained across keep-alive requests.
type Reader struct {
	upstream io.Reader
	limit int
	total int
	line int
	previous byte
	pending bool
}

func NewReader(upstream io.Reader) *Reader { return &Reader{upstream: upstream} }

// Begin also counts bytes prefetched by the previous request/body. Peek does
// not consume them, so pipelined headers and CONNECT payload remain intact.
func (r *Reader) Begin(reader *bufio.Reader, limit int) error {
	r.limit, r.total, r.line, r.previous, r.pending = limit, 0, 0, 0, true
	buffered, err := reader.Peek(reader.Buffered())
	if err != nil { return err }
	return r.scan(buffered)
}

func (r *Reader) Read(p []byte) (int, error) {
	if len(p) == 0 { return 0, nil }
	if r.pending && r.total > r.limit { return 0, ErrHeaderTooLarge }
	if r.pending && len(p) > r.limit-r.total+1 {
		p = p[:r.limit-r.total+1]
	}
	n, err := r.upstream.Read(p)
	if scanErr := r.scan(p[:n]); scanErr != nil {
		// Oversized requests are closed; do not expose the offending fragment
		// to net/http's unbounded line/header allocation paths.
		return 0, scanErr
	}
	return n, err
}

func (r *Reader) scan(p []byte) error {
	for _, value := range p {
		if !r.pending { break }
		r.total++
		if r.total > r.limit { return ErrHeaderTooLarge }
		r.line++
		if value == '\n' {
			if r.line == 1 || r.line == 2 && r.previous == '\r' {
				r.pending = false
				break
			}
			r.line = 0
		}
		r.previous = value
	}
	return nil
}

// Gate limits only requests awaiting authentication. The deadline is absolute
// for a lease; failed-auth keep-alive retries must reuse the same lease.
type Gate struct {
	pending chan struct{}
	HeaderBytes int
	timeout time.Duration
}

func NewGate(capacity, headerBytes int, timeout time.Duration) *Gate {
	return &Gate{pending: make(chan struct{}, capacity), HeaderBytes: headerBytes, timeout: timeout}
}

type Lease struct {
	gate *Gate
	ctx context.Context
	conn net.Conn
	stopCancel func() bool
	once sync.Once
}

func (g *Gate) Begin(ctx context.Context, conn net.Conn) (*Lease, error) {
	if err := ctx.Err(); err != nil { return nil, err }
	select {
	case g.pending <- struct{}{}:
	default:
		return nil, ErrCapacity
	}
	lease := &Lease{gate: g, ctx: ctx, conn: conn}
	if err := conn.SetDeadline(time.Now().Add(g.timeout)); err != nil {
		lease.release()
		return nil, err
	}
	lease.stopCancel = context.AfterFunc(ctx, func() {
		_ = conn.Close()
		lease.release()
	})
	return lease, nil
}

// Admit runs synchronously in the TCP accept loop, before a parser goroutine
// is created. Closing the admitted connection also returns its initial lease.
func (g *Gate) Admit(ctx context.Context, conn net.Conn) (net.Conn, error) {
	lease, err := g.Begin(ctx, conn)
	if err != nil { return nil, err }
	return &admittedConn{Conn: conn, lease: lease}, nil
}

type admittedConn struct {
	net.Conn
	lease *Lease
}

func (c *admittedConn) Close() error { c.lease.End(); return c.Conn.Close() }

// Preserve sing's TCP half-close/optional-I/O interfaces after authentication.
// The header Reader remains opaque while bytes are being parsed.
func (c *admittedConn) Upstream() any { return c.Conn }
func (c *admittedConn) ReaderReplaceable() bool { return true }
func (c *admittedConn) WriterReplaceable() bool { return true }

func AdmittedLease(conn net.Conn) *Lease {
	if admitted, ok := conn.(*admittedConn); ok { return admitted.lease }
	return nil
}

func (l *Lease) release() { l.once.Do(func() { <-l.gate.pending }) }

// End releases an unsuccessful or abandoned handshake. Its caller owns
// closing the connection; cancellation closes it immediately.
func (l *Lease) End() { l.stopCancel(); l.release() }

// Complete clears both deadlines before a body, upgrade or CONNECT tunnel is
// forwarded and returns capacity immediately, independently of tunnel life.
func (l *Lease) Complete() error {
	l.stopCancel()
	err := l.ctx.Err()
	if err == nil { err = l.conn.SetDeadline(time.Time{}) }
	l.release()
	return err
}
