package listener

import (
	"context"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/internal/discordaccess/httpguard"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
)

type admissionTestListener struct { connections []net.Conn; index int }
func (listener *admissionTestListener) Accept() (net.Conn, error) {
	if listener.index == len(listener.connections) { return nil, net.ErrClosed }
	conn := listener.connections[listener.index]
	listener.index++
	return conn, nil
}
func (listener *admissionTestListener) Close() error { return nil }
func (listener *admissionTestListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127,0,0,1), Port: 1} }

type admissionTestConn struct { net.Conn; closed atomic.Bool }
func (conn *admissionTestConn) Close() error { conn.closed.Store(true); return conn.Conn.Close() }

type admissionTestHandler struct {
	gate *httpguard.Gate
	started chan net.Conn
	release chan struct{}
	finished sync.WaitGroup
}
func (handler *admissionTestHandler) PrepareConnection(ctx context.Context, conn net.Conn) (net.Conn, error) {
	prepared, err := handler.gate.Admit(ctx, conn)
	if err == nil { handler.finished.Add(1) }
	return prepared, err
}
func (handler *admissionTestHandler) NewConnection(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	defer handler.finished.Done()
	handler.started <- conn
	<-handler.release
	conn.Close()
}

func TestHTTPAdmissionRunsBeforeParserGoroutine(t *testing.T) {
	const capacity = 128
	connections := make([]net.Conn, capacity+64)
	tracked := make([]*admissionTestConn, len(connections))
	for index := range connections {
		server, client := net.Pipe()
		t.Cleanup(func() { server.Close(); client.Close() })
		tracked[index] = &admissionTestConn{Conn: server}
		connections[index] = tracked[index]
	}
	handler := &admissionTestHandler{gate: httpguard.NewGate(capacity, 64<<10, time.Second), started: make(chan net.Conn, len(connections)), release: make(chan struct{})}
	var releaseOnce sync.Once
	t.Cleanup(func() { releaseOnce.Do(func() { close(handler.release) }) })
	listener := &Listener{ctx: context.Background(), logger: logger.NOP(), connHandler: handler, tcpListener: &admissionTestListener{connections: connections}}
	listener.shutdown.Store(true)
	listener.loopTCPIn()
	// The accept loop has processed every socket while admitted parsers remain
	// blocked. Excess sockets must already be closed without a parser launch.
	for index, conn := range tracked {
		if actual, expected := conn.closed.Load(), index >= capacity; actual != expected { t.Errorf("socket %d closed=%v, expected %v", index, actual, expected) }
	}
	for range capacity {
		select {
		case <-handler.started:
		case <-time.After(2*time.Second): t.Fatal("admitted parser did not start")
		}
	}
	select {
	case <-handler.started: t.Error("an overflow socket started a parser")
	default:
	}
	releaseOnce.Do(func() { close(handler.release) })
	handler.finished.Wait()
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	prepared, err := handler.gate.Admit(context.Background(), server)
	if err != nil { t.Fatalf("closing admitted connections did not release capacity: %v", err) }
	prepared.Close()
}

type ordinaryTestHandler struct { handled atomic.Int32; finished sync.WaitGroup }
func (handler *ordinaryTestHandler) NewConnection(ctx context.Context, conn net.Conn, metadata adapter.InboundContext, onClose N.CloseHandlerFunc) {
	defer handler.finished.Done()
	handler.handled.Add(1)
	conn.Close()
}

func TestNonHTTPListenerWithoutAdmissionHookKeepsBehavior(t *testing.T) {
	const count = 192
	connections := make([]net.Conn, count)
	for index := range connections {
		server, client := net.Pipe()
		t.Cleanup(func() { server.Close(); client.Close() })
		connections[index] = server
	}
	handler := &ordinaryTestHandler{}
	handler.finished.Add(count)
	listener := &Listener{ctx: context.Background(), logger: logger.NOP(), connHandler: handler, tcpListener: &admissionTestListener{connections: connections}}
	listener.shutdown.Store(true)
	listener.loopTCPIn()
	handler.finished.Wait()
	if actual := handler.handled.Load(); actual != count { t.Fatalf("ordinary inbound handled %d of %d", actual, count) }
}

func TestAdmittedConnectionPreservesUnderlyingOptionalIO(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	gate := httpguard.NewGate(1, 64<<10, time.Second)
	prepared, err := gate.Admit(context.Background(), server)
	if err != nil { t.Fatal(err) }
	defer prepared.Close()
	if actual := N.UnwrapReader(prepared); actual != server { t.Fatalf("reader no longer reaches underlying TCP optional I/O: %T", actual) }
	if actual := N.UnwrapWriter(prepared); actual != server { t.Fatalf("writer no longer reaches underlying TCP half-close: %T", actual) }
}
