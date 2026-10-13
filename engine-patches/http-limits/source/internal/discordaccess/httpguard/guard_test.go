package httpguard

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fragmentReader struct { reader io.Reader; size int }
func (r *fragmentReader) Read(p []byte) (int, error) {
	if len(p) > r.size { p = p[:r.size] }
	return r.reader.Read(p)
}

func TestHeaderBudget(t *testing.T) {
	const limit = 64 << 10
	base := "GET http://discord.com/ HTTP/1.1\r\nX-Pad: "
	exact := base + strings.Repeat("x", limit-len(base)-4) + "\r\n\r\n"
	for _, tc := range []struct { name, request string; tooLarge bool }{
		{"exact", exact, false},
		{"one_over", base + strings.Repeat("x", limit-len(base)-3) + "\r\n\r\n", true},
		{"request_line", "GET /" + strings.Repeat("x", limit) + " HTTP/1.1\r\n\r\n", true},
		{"many_headers", "GET / HTTP/1.1\r\n" + strings.Repeat("X: a\r\n", limit/5) + "\r\n", true},
		{"folded_header", "GET / HTTP/1.1\r\nX: a\r\n" + strings.Repeat(" a\r\n", limit/3) + "\r\n", true},
		{"lf", "GET / HTTP/1.1\nX: a\n\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, fragment := range []int{1, 4096, limit * 2} {
				guard := NewReader(&fragmentReader{strings.NewReader(tc.request), fragment})
				reader := bufio.NewReader(guard)
				if err := guard.Begin(reader, limit); err != nil { t.Fatal(err) }
				_, err := http.ReadRequest(reader)
				if tc.tooLarge && !errors.Is(err, ErrHeaderTooLarge) { t.Fatalf("fragment %d: wanted header limit, got %v", fragment, err) }
				if !tc.tooLarge && err != nil { t.Fatalf("fragment %d: %v", fragment, err) }
			}
		})
	}
}

func TestBufferedPipelinedHeaderAndLargeBody(t *testing.T) {
	body := bytes.Repeat([]byte("x\r\n\r\ny"), 32<<10)
	head := "POST http://discord.com/upload HTTP/1.1\r\nContent-Length: " + strconv.Itoa(len(body)) + "\r\n\r\n"
	second := "GET http://discord.com/next HTTP/1.1\r\nX: second\r\n\r\n"
	guard := NewReader(io.MultiReader(strings.NewReader(head), bytes.NewReader(body), strings.NewReader(second)))
	reader := bufio.NewReader(guard)
	if err := guard.Begin(reader, 64<<10); err != nil { t.Fatal(err) }
	request, err := http.ReadRequest(reader)
	if err != nil { t.Fatal(err) }
	actual, err := io.ReadAll(request.Body)
	if err != nil || !bytes.Equal(body, actual) { t.Fatalf("body: %d bytes, %v", len(actual), err) }
	if _, err = reader.Peek(1); err != nil { t.Fatal(err) }
	if err = guard.Begin(reader, len(second)); err != nil { t.Fatal(err) }
	request, err = http.ReadRequest(reader)
	if err != nil || request.URL.Path != "/next" { t.Fatalf("second request: %v, %v", request, err) }
}

func TestBufferedSecondRequestCannotBypassBudget(t *testing.T) {
	first := "GET / HTTP/1.1\r\n\r\n"
	second := "GET / HTTP/1.1\r\nX: " + strings.Repeat("x", 200) + "\r\n\r\n"
	guard := NewReader(strings.NewReader(first + second))
	reader := bufio.NewReader(guard)
	if err := guard.Begin(reader, 128); err != nil { t.Fatal(err) }
	if _, err := http.ReadRequest(reader); err != nil { t.Fatal(err) }
	if reader.Buffered() == 0 { t.Fatal("test must exercise prefetched second request bytes") }
	err := guard.Begin(reader, 128)
	if err == nil { _, err = http.ReadRequest(reader) }
	if !errors.Is(err, ErrHeaderTooLarge) { t.Fatalf("got %v", err) }
}

func TestCONNECTPayloadBeyondHeaderBudgetPreserved(t *testing.T) {
	head := "CONNECT discord.com:443 HTTP/1.1\r\n\r\n"
	payload := bytes.Repeat([]byte{0x16, 0x03, 0x03, 0, 0xff, '\n', '\r'}, 64<<10)
	guard := NewReader(bytes.NewReader(append([]byte(head), payload...)))
	reader := bufio.NewReader(guard)
	if err := guard.Begin(reader, len(head)); err != nil { t.Fatal(err) }
	if _, err := http.ReadRequest(reader); err != nil { t.Fatal(err) }
	actual, err := io.ReadAll(reader)
	if err != nil || !bytes.Equal(actual, payload) { t.Fatalf("payload: %d bytes, %v", len(actual), err) }
}

func TestGateAdmitsFrontendBurstAndBoundsPendingConnections(t *testing.T) {
	gate := NewGate(128, 64<<10, time.Second)
	leases := make([]*Lease, 128)
	var workers sync.WaitGroup
	for index := range 64 {
		workers.Add(1)
		go func(index int) {
			defer workers.Done()
			server, client := net.Pipe()
			t.Cleanup(func() { server.Close(); client.Close() })
			lease, err := gate.Begin(context.Background(), server)
			if err != nil { t.Errorf("frontend connection %d: %v", index, err); return }
			leases[index] = lease
		}(index)
	}
	workers.Wait()
	for index := 64; index < len(leases); index++ {
		server, client := net.Pipe()
		t.Cleanup(func() { server.Close(); client.Close() })
		lease, err := gate.Begin(context.Background(), server)
		if err != nil { t.Fatal(err) }
		leases[index] = lease
	}
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	if _, err := gate.Begin(context.Background(), server); !errors.Is(err, ErrCapacity) { t.Fatalf("overflow: %v", err) }
	for _, lease := range leases { if lease != nil { lease.End() } }
	lease, err := gate.Begin(context.Background(), server)
	if err != nil { t.Fatalf("capacity not returned: %v", err) }
	lease.End(); lease.End()
}

func TestSlowHeaderDeadlineAndRelease(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	gate := NewGate(1, 64<<10, 40*time.Millisecond)
	lease, err := gate.Begin(context.Background(), server)
	if err != nil { t.Fatal(err) }
	guard := NewReader(server)
	reader := bufio.NewReader(guard)
	if err = guard.Begin(reader, gate.HeaderBytes); err != nil { t.Fatal(err) }
	go client.Write([]byte("GET / HTTP/1.1\r\nX: stalled"))
	_, err = http.ReadRequest(reader)
	lease.End()
	if !errors.Is(err, os.ErrDeadlineExceeded) { t.Fatalf("slow header: %v", err) }
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	lease, err = gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatalf("capacity not released: %v", err) }
	lease.End()
}

func TestCancellationClosesAndReturnsCapacity(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	gate := NewGate(1, 64<<10, time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	lease, err := gate.Begin(ctx, server)
	if err != nil { t.Fatal(err) }
	cancel()
	client.SetReadDeadline(time.Now().Add(time.Second))
	if _, err = client.Read(make([]byte, 1)); err != io.EOF { t.Fatalf("connection not closed: %v", err) }
	lease.End()
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	lease, err = gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatal(err) }
	lease.End()
}

func TestAuthenticatedTunnelHasNoDeadlineOrCapacityLease(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close(); defer client.Close()
	gate := NewGate(1, 64<<10, 20*time.Millisecond)
	lease, err := gate.Begin(context.Background(), server)
	if err != nil { t.Fatal(err) }
	if err = lease.Complete(); err != nil { t.Fatal(err) }
	otherServer, otherClient := net.Pipe()
	defer otherServer.Close(); defer otherClient.Close()
	otherLease, err := gate.Begin(context.Background(), otherServer)
	if err != nil { t.Fatalf("tunnel still owns pending capacity: %v", err) }
	otherLease.End()
	time.Sleep(60*time.Millisecond)
	payload := bytes.Repeat([]byte{0, 0xff, '\r', '\n'}, 128<<10)
	go func() { client.Write(payload); client.Close() }()
	actual, err := io.ReadAll(server)
	if err != nil || !bytes.Equal(actual, payload) { t.Fatalf("tunnel after original deadline: %d bytes, %v", len(actual), err) }
}
