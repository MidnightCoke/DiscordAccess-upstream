package http

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	std_http "net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/sing-box/internal/discordaccess/httpguard"
	"github.com/sagernet/sing/common/auth"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type boundedTestHandler func(context.Context, net.Conn, M.Socksaddr, M.Socksaddr, N.CloseHandlerFunc)
func (handler boundedTestHandler) NewConnectionEx(ctx context.Context, conn net.Conn, source M.Socksaddr, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	handler(ctx, conn, source, destination, onClose)
}

func startBoundedTestSession(t *testing.T, ctx context.Context, gate *httpguard.Gate, handler N.TCPConnectionHandlerEx) (net.Conn, <-chan error) {
	t.Helper()
	server, client := net.Pipe()
	t.Cleanup(func() { server.Close(); client.Close() })
	client.SetDeadline(time.Now().Add(5*time.Second))
	lease, err := gate.Begin(ctx, server)
	if err != nil { t.Fatal(err) }
	guard := httpguard.NewReader(server)
	result := make(chan error, 1)
	go func() {
		err := handleBoundedConnection(ctx, server, bufio.NewReader(guard), guard, gate, lease,
			auth.NewAuthenticator([]auth.User{{Username: "user", Password: "test-secret"}}), handler, M.Socksaddr{}, nil)
		if err != nil { server.Close() }
		result <- err
	}()
	return client, result
}

func boundedTestAuthorization() string { return "Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("user:test-secret")) + "\r\n" }

func expectBoundedTestResponse(t *testing.T, reader *bufio.Reader, code int, content string) {
	t.Helper()
	response, err := std_http.ReadResponse(reader, nil)
	if err != nil { t.Fatal(err) }
	defer response.Body.Close()
	if response.StatusCode != code { t.Fatalf("status %d, wanted %d", response.StatusCode, code) }
	if content != "" {
		body, err := io.ReadAll(response.Body)
		if err != nil || string(body) != content { t.Fatalf("response body %q: %v", body, err) }
	}
}

func requireBoundedTestResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result: return err
	case <-time.After(3*time.Second): t.Fatal("handler did not finish"); return nil
	}
}

func readBoundedTunnel(t *testing.T, conn net.Conn, count int) []byte {
	t.Helper()
	type readResult struct { data []byte; err error }
	result := make(chan readResult, 1)
	go func() {
		data := make([]byte, count)
		_, err := io.ReadFull(conn, data)
		result <- readResult{data, err}
	}()
	select {
	case actual := <-result:
		if actual.err != nil { t.Fatal(actual.err) }
		return actual.data
	case <-time.After(2*time.Second):
		t.Fatal("tunnel read did not complete")
		return nil
	}
}

func TestBoundedUnauthenticatedKeepAliveSecondHeader(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, time.Second)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHandler(func(context.Context, net.Conn, M.Socksaddr, M.Socksaddr, N.CloseHandlerFunc) { t.Error("unauthenticated route") }))
	reader := bufio.NewReader(client)
	first := "GET http://discord.com/ HTTP/1.1\r\nProxy-Connection: keep-alive\r\n\r\n"
	second := "GET http://discord.com/ HTTP/1.1\r\nX: " + strings.Repeat("x", 64<<10) + "\r\n\r\n"
	go client.Write([]byte(first + second))
	expectBoundedTestResponse(t, reader, std_http.StatusProxyAuthRequired, "")
	if err := requireBoundedTestResult(t, result); !errors.Is(err, httpguard.ErrHeaderTooLarge) { t.Fatalf("second header: %v", err) }
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	lease, err := gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatalf("capacity leaked: %v", err) }
	lease.End()
}

func TestBoundedFailedAuthRetriesKeepAbsoluteDeadline(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, time.Second)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHandler(func(context.Context, net.Conn, M.Socksaddr, M.Socksaddr, N.CloseHandlerFunc) { t.Error("unauthenticated route") }))
	reader := bufio.NewReader(client)
	request := "GET http://discord.com/ HTTP/1.1\r\nProxy-Connection: keep-alive\r\n\r\n"
	if _, err := io.WriteString(client, request); err != nil { t.Fatal(err) }
	expectBoundedTestResponse(t, reader, std_http.StatusProxyAuthRequired, "")
	time.Sleep(700*time.Millisecond)
	if _, err := io.WriteString(client, request); err != nil { t.Fatal(err) }
	expectBoundedTestResponse(t, reader, std_http.StatusProxyAuthRequired, "")
	started := time.Now()
	err := requireBoundedTestResult(t, result)
	if !errors.Is(err, os.ErrDeadlineExceeded) { t.Fatalf("deadline: %v", err) }
	if elapsed := time.Since(started); elapsed >= 700*time.Millisecond { t.Fatalf("failed-auth retry reset absolute deadline: %s", elapsed) }
}

func TestBoundedCONNECTPreservesPacketPayloadAndLongTunnel(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, 250*time.Millisecond)
	routed := make(chan net.Conn, 1)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHandler(func(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
		if user, ok := auth.UserFromContext[string](ctx); !ok || user != "user" { t.Errorf("authentication context: %q, %v", user, ok) }
		if destination.Fqdn != "discord.com" || destination.Port != 443 { t.Errorf("destination %v", destination) }
		routed <- conn
	}))
	head := "CONNECT discord.com:443 HTTP/1.1\r\n" + boundedTestAuthorization() + "\r\n"
	payload := bytes.Repeat([]byte{0x16, 0x03, 0x03, 0xff, '\r', '\n'}, 32<<10)
	go client.Write(append([]byte(head), payload...))
	// Like the upstream CONNECT client, inspect the response header only; its
	// Body is the tunnel and must not be closed or drained as an HTTP body.
	response, err := std_http.ReadResponse(bufio.NewReader(client), &std_http.Request{Method: "CONNECT"})
	if err != nil || response.StatusCode != std_http.StatusOK { t.Fatalf("CONNECT response: %v, %v", response, err) }
	if err := requireBoundedTestResult(t, result); err != nil { t.Fatal(err) }
	conn := <-routed
	t.Cleanup(func() { conn.Close() })
	// A tunnel must release capacity while still open.
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	lease, err := gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatalf("tunnel held pending slot: %v", err) }
	lease.End()
	time.Sleep(750*time.Millisecond)
	actual := readBoundedTunnel(t, conn, len(payload))
	if !bytes.Equal(payload, actual) { t.Fatal("CONNECT payload changed") }
	go client.Write([]byte("still alive"))
	actual = readBoundedTunnel(t, conn, len("still alive"))
	if string(actual) != "still alive" { t.Fatalf("long tunnel: %q", actual) }
}

func boundedTestHTTPBackend(t *testing.T, bodies chan<- []byte, delay time.Duration) boundedTestHandler {
	return boundedTestHandler(func(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
		defer conn.Close()
		request, err := std_http.ReadRequest(bufio.NewReader(conn))
		if err != nil { t.Errorf("upstream request: %v", err); return }
		if delay != 0 { time.Sleep(delay) }
		body, err := io.ReadAll(request.Body)
		if err != nil { t.Errorf("upstream body: %v", err); return }
		if bodies != nil { bodies <- body }
		if _, err = io.WriteString(conn, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); err != nil { t.Errorf("upstream response: %v", err) }
	})
}

func TestBoundedLargeBodyAndPipelinedAuthenticatedRequests(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, 500*time.Millisecond)
	bodies := make(chan []byte, 2)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHTTPBackend(t, bodies, 1500*time.Millisecond))
	body := bytes.Repeat([]byte("body\r\n\r\n"), 40<<10)
	first := fmt.Sprintf("POST http://discord.com/upload HTTP/1.1\r\nHost: discord.com\r\n%sProxy-Connection: keep-alive\r\nContent-Length: %d\r\n\r\n", boundedTestAuthorization(), len(body))
	second := "GET http://discord.com/next HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Proxy-Connection: keep-alive\r\n\r\n"
	go client.Write(append(append([]byte(first), body...), []byte(second)...))
	reader := bufio.NewReader(client)
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	if actual := <-bodies; !bytes.Equal(actual, body) { t.Fatalf("large body truncated: %d", len(actual)) }
	if actual := <-bodies; len(actual) != 0 { t.Fatalf("next body: %d", len(actual)) }
	client.Close()
	if err := requireBoundedTestResult(t, result); err != io.EOF { t.Fatalf("closed keep-alive: %v", err) }
}

func TestBoundedAuthenticatedKeepAliveIdleDoesNotUseAuthDeadline(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, 250*time.Millisecond)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHTTPBackend(t, nil, 0))
	request := "GET http://discord.com/next HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Proxy-Connection: keep-alive\r\n\r\n"
	reader := bufio.NewReader(client)
	if _, err := io.WriteString(client, request); err != nil { t.Fatal(err) }
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	time.Sleep(750*time.Millisecond)
	// Idle authenticated HTTP must also leave pending capacity available.
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	lease, err := gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatalf("idle keep-alive held pending capacity: %v", err) }
	lease.End()
	if _, err = io.WriteString(client, request); err != nil { t.Fatal(err) }
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	client.Close()
	if err := requireBoundedTestResult(t, result); err != io.EOF { t.Fatal(err) }
}

func TestBoundedSecondRequestStillRequiresAuthentication(t *testing.T) {
	gate := httpguard.NewGate(1, 64<<10, time.Second)
	client, result := startBoundedTestSession(t, context.Background(), gate, boundedTestHTTPBackend(t, nil, 0))
	first := "GET http://discord.com/first HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Proxy-Connection: keep-alive\r\n\r\n"
	second := "GET http://discord.com/second HTTP/1.1\r\nHost: discord.com\r\n\r\n"
	go client.Write([]byte(first + second))
	reader := bufio.NewReader(client)
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	expectBoundedTestResponse(t, reader, std_http.StatusProxyAuthRequired, "")
	if err := requireBoundedTestResult(t, result); err == nil { t.Fatal("second request bypassed authentication") }
}

func TestBoundedPendingCloseAndCancellationReleaseCapacity(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		t.Run(fmt.Sprint("cancelled_", cancelled), func(t *testing.T) {
			gate := httpguard.NewGate(1, 64<<10, time.Second)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			client, result := startBoundedTestSession(t, ctx, gate, boundedTestHTTPBackend(t, nil, 0))
			if cancelled { cancel() } else { client.Close() }
			if err := requireBoundedTestResult(t, result); err == nil { t.Fatal("expected closed pending handshake") }
			server, otherClient := net.Pipe()
			defer server.Close(); defer otherClient.Close()
			lease, err := gate.Begin(context.Background(), server)
			if err != nil { t.Fatalf("pending capacity leaked: %v", err) }
			lease.End()
		})
	}
}

func TestBoundedChunkedUploadTrailersAndPipelinedNextRequest(t *testing.T) {
	type received struct { body []byte; trailer string }
	receivedBodies := make(chan received, 2)
	handler := boundedTestHandler(func(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
		defer conn.Close()
		request, err := std_http.ReadRequest(bufio.NewReader(conn))
		if err != nil { t.Errorf("chunked upstream header: %v", err); return }
		body, err := io.ReadAll(request.Body)
		if err != nil { t.Errorf("chunked upstream body: %v", err); return }
		receivedBodies <- received{body, request.Trailer.Get("X-Body-SHA")}
		if _, err = io.WriteString(conn, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); err != nil { t.Errorf("chunked response: %v", err) }
	})
	gate := httpguard.NewGate(1, 64<<10, time.Second)
	client, result := startBoundedTestSession(t, context.Background(), gate, handler)
	body := bytes.Repeat([]byte("chunk\r\n\r\n"), 24<<10)
	head := "POST http://discord.com/upload HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Proxy-Connection: keep-alive\r\nTransfer-Encoding: chunked\r\nTrailer: X-Body-SHA\r\n\r\n"
	chunk := append([]byte(fmt.Sprintf("%x\r\n", len(body))), body...)
	chunk = append(chunk, []byte("\r\n0\r\nX-Body-SHA: preserved\r\n\r\n")...)
	second := "GET http://discord.com/next HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Proxy-Connection: keep-alive\r\n\r\n"
	go client.Write(append(append([]byte(head), chunk...), []byte(second)...))
	reader := bufio.NewReader(client)
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	expectBoundedTestResponse(t, reader, std_http.StatusOK, "ok")
	firstBody := <-receivedBodies
	if !bytes.Equal(firstBody.body, body) || firstBody.trailer != "preserved" { t.Fatalf("chunk/trailer changed: %d bytes, %q", len(firstBody.body), firstBody.trailer) }
	if nextBody := <-receivedBodies; len(nextBody.body) != 0 { t.Fatal("pipelined next body changed") }
	client.Close()
	if err := requireBoundedTestResult(t, result); err != io.EOF { t.Fatal(err) }
}

func TestBoundedUpgradePreservesPrefetchedPayloadAndLongSession(t *testing.T) {
	payload := bytes.Repeat([]byte{0x82, 0xff, 0x00, 0x0a, 0x0d}, 32<<10)
	received := make(chan []byte, 2)
	handler := boundedTestHandler(func(ctx context.Context, conn net.Conn, source, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
		defer conn.Close()
		reader := bufio.NewReader(conn)
		request, err := std_http.ReadRequest(reader)
		if err != nil { t.Errorf("upgrade request: %v", err); return }
		if request.Header.Get("Upgrade") != "websocket" { t.Error("upgrade header changed") }
		// The proxy writes prefetched payload before starting its copy loop.
		// Send the response concurrently so neither pipe direction blocks it.
		responseWritten := make(chan error, 1)
		go func() { _, err := io.WriteString(conn, "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"); responseWritten <- err }()
		actual := make([]byte, len(payload))
		if _, err = io.ReadFull(reader, actual); err != nil { t.Errorf("upgrade payload: %v", err); return }
		received <- actual
		if err = <-responseWritten; err != nil { t.Errorf("upgrade response: %v", err); return }
		actual = make([]byte, len("late websocket bytes"))
		if _, err = io.ReadFull(reader, actual); err != nil { t.Errorf("late upgrade payload: %v", err); return }
		received <- actual
	})
	gate := httpguard.NewGate(1, 64<<10, 250*time.Millisecond)
	client, result := startBoundedTestSession(t, context.Background(), gate, handler)
	head := "GET http://discord.com/gateway HTTP/1.1\r\nHost: discord.com\r\n" + boundedTestAuthorization() + "Connection: upgrade\r\nUpgrade: websocket\r\n\r\n"
	go client.Write(append([]byte(head), payload...))
	expectBoundedTestResponse(t, bufio.NewReader(client), std_http.StatusSwitchingProtocols, "")
	select {
	case actual := <-received:
		if !bytes.Equal(actual, payload) { t.Fatal("prefetched upgrade payload changed") }
	case <-time.After(2*time.Second): t.Fatal("upgrade payload did not arrive")
	}
	time.Sleep(750*time.Millisecond)
	if _, err := io.WriteString(client, "late websocket bytes"); err != nil { t.Fatal(err) }
	select {
	case actual := <-received:
		if string(actual) != "late websocket bytes" { t.Fatal("late upgrade payload changed") }
	case <-time.After(2*time.Second): t.Fatal("upgrade retained the authentication deadline")
	}
	client.Close()
	_ = requireBoundedTestResult(t, result)
}
