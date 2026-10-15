package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	cbor "github.com/fxamacker/cbor/v2"
	"crypto/sha256"
	"encoding/base64"
	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"

	"github.com/katzenpost/katzenpost/client/thin"
	"github.com/katzenpost/katzenpost/client/config"
)

type ChatRequest struct {
	Op        string   `cbor:"op"`
	UserID    []byte   `cbor:"user_id,omitempty"`
	Recipient []byte   `cbor:"recipient,omitempty"`
	Content   string   `cbor:"content,omitempty"`
	MsgType   string   `cbor:"msg_type,omitempty"`
	GroupID   string   `cbor:"group_id,omitempty"`
	GroupName string   `cbor:"group_name,omitempty"`
	Members   [][]byte `cbor:"members,omitempty"`
}

type ChatMessage struct {
	ID        string `cbor:"id"`
	Sender    []byte `cbor:"sender"`
	Content   string `cbor:"content"`
	Type      string `cbor:"type"`
	Timestamp int64  `cbor:"ts"`
	GroupID   string `cbor:"group_id,omitempty"`
}

type Group struct {
	ID        string   `cbor:"id"`
	Name      string   `cbor:"name"`
	Owner     []byte   `cbor:"owner"`
	Members   [][]byte `cbor:"members"`
	CreatedAt int64    `cbor:"created_at"`
}

type ChatResponse struct {
	Success  bool          `cbor:"success"`
	Error    string        `cbor:"error,omitempty"`
	Messages []ChatMessage `cbor:"messages,omitempty"`
	Addr     string        `cbor:"addr,omitempty"`
	GroupID  string        `cbor:"group_id,omitempty"`
	Groups   []Group       `cbor:"groups,omitempty"`
}

func loadOrCreateIdentity(dir string) ([]byte, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "identity")
	if b, err := os.ReadFile(path); err == nil && len(b) == 16 {
		return b, nil
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, id, 0600); err != nil {
		return nil, err
	}
	return id, nil
}

func main() {
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: zkchat [flags] <command> [args]

Commands:
  send [-via <netID>] [--e2e] <recipient_hex> <message>
    Send via +chat; --via <netID> routes an opaque envelope through the
    local +meshbridge (cross-domain); --e2e seals the body to the peer key.

  poll <config.toml>
    Poll for new messages addressed to you.

  ai <config.toml> <recipient_hex> <prompt>
    Send a prompt to the AI inference service via chat.

  group create <config.toml> <name> [member_hex...]
    Create a new group with optional initial members.

  group send <config.toml> <group_id> <message>
    Send a message to a group.

  group poll <config.toml> [group_id]
    Poll for group messages. If group_id is omitted, polls all groups.

  group invite <config.toml> <group_id> <member_hex> [member_hex...]
    Add members to a group (owner only).

  group leave <config.toml> <group_id>
    Leave a group.

  group list <config.toml>
    List your groups.

Flags:
`)
		flag.PrintDefaults()
	}

	flag.Parse()
	args := flag.Args()
	if len(args) < 1 {
		flag.Usage()
		os.Exit(1)
	}

	cmd := args[0]
	switch cmd {
	case "send":
		cmdSend(args[1:])
	case "poll":
		cmdPoll(args[1:])
	case "ai":
		cmdAI(args[1:])
	case "group":
		cmdGroup(args[1:])
	case "e2e-export":
		cmdE2EExport(args[1:])
	case "e2e-import":
		cmdE2EImport(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", cmd)
		flag.Usage()
		os.Exit(1)
	}
}

func cmdGroup(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group <subcommand> [args]")
		fmt.Fprintln(os.Stderr, "Subcommands: create, send, poll, invite, leave, list")
		os.Exit(1)
	}
	sub := args[0]
	switch sub {
	case "create":
		groupCreate(args[1:])
	case "send":
		groupSend(args[1:])
	case "poll":
		groupPoll(args[1:])
	case "invite":
		groupInvite(args[1:])
	case "leave":
		groupLeave(args[1:])
	case "list":
		groupList(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "Unknown group subcommand: %s\n", sub)
		os.Exit(1)
	}
}

// MeshRequest is the +meshbridge capability wire request (mirrors cmd/mesh-bridge).
type MeshRequest struct {
	Op        string `cbor:"op"`                  // "relay"
	NetID     string `cbor:"net_id"`              // peer domain alias from the bridge address book
	Recipient string `cbor:"recipient,omitempty"` // hex of the 16-byte peer identity
	Content   string `cbor:"content,omitempty"`   // opaque body (E2E-sealed when --e2e)
}

// MeshResponse is the +meshbridge reply.
type MeshResponse struct {
	Success bool   `cbor:"success"`
	Error   string `cbor:"error,omitempty"`
	Peer    string `cbor:"peer,omitempty"`
}

// findMeshBridgeService resolves the local domain's +meshbridge capability.
func findMeshBridgeService(client *thin.ThinClient) (*[32]byte, []byte, error) {
	for i := 0; i < 100; i++ {
		if client.PKIDocument() != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	var lastErr error
	for i := 0; i < 10; i++ {
		s, err := client.GetService("meshbridge")
		if err == nil {
			h := blake2b.Sum256(s.MixDescriptor.IdentityKey)
			return &h, s.RecipientQueueID, nil
		}
		lastErr = err
		time.Sleep(1 * time.Second)
	}
	return nil, nil, lastErr
}

func sendViaBridge(client *thin.ThinClient, netID, recipHex, content string) (MeshResponse, error) {
	destHash, queue, err := findMeshBridgeService(client)
	if err != nil {
		return MeshResponse{}, fmt.Errorf("meshbridge service: %w", err)
	}
	req, _ := cbor.Marshal(MeshRequest{Op: "relay", NetID: netID, Recipient: recipHex, Content: content})
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	reply, err := client.BlockingSendMessage(ctx, req, destHash, queue)
	if err != nil {
		return MeshResponse{}, fmt.Errorf("send: %w", err)
	}
	var resp MeshResponse
	cbor.UnmarshalFirst(reply, &resp)
	return resp, nil
}

// ---- E2E content keys (crypto in the client; chatd and any bridge see ciphertext) ----

// cfgDirFor returns the identity directory the CLI derives from the thin config.
func cfgDirFor(configPath string) string {
	return filepath.Dir(configPath)
}

// loadOrCreateE2EKeypair generates a per-identity file (X25519 scalar + pub) if absent
// and returns the *private* scalar.
func loadOrCreateE2EKeypair(dir string) ([]byte, []byte) {
	privPath := filepath.Join(dir, "e2e.keypair")
	if raw, err := os.ReadFile(privPath); err == nil && len(raw) == 64 {
		// 32B scalar || 32B pub
		scalar := make([]byte, 32)
		copy(scalar, raw[:32])
		pub := make([]byte, 32)
		copy(pub, raw[32:])
		return scalar, pub
	}
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		fmt.Fprintln(os.Stderr, "e2e keygen: rand:", err)
		os.Exit(1)
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e keygen:", err)
		os.Exit(1)
	}
	os.WriteFile(privPath, append(append([]byte{}, priv...), pub...), 0600)
	return priv, pub
}

func loadE2EPub(dir string, peerHex string) ([]byte, bool) {
	pubPath := filepath.Join(dir, "e2e-pubs", peerHex+".pub")
	raw, err := os.ReadFile(pubPath)
	if err != nil || len(raw) < 32 {
		return nil, false
	}
	return raw[:32], true
}

// e2eSeal: ephemeral X25519 for each message; cha-20poly1305 keyed by SHA256(shared);
// payload = nonce(24) || ephPub(32) || ct
func e2eSeal(pub []byte, plaintext []byte) (string, error) {
	var recvPub [32]byte
	copy(recvPub[:], pub)
	var ephPriv [32]byte
	if _, err := rand.Read(ephPriv[:]); err != nil {
		return "", err
	}
	ephPub, err := curve25519.X25519(ephPriv[:], curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	shared, err := curve25519.X25519(ephPriv[:], recvPub[:])
	if err != nil {
		return "", err
	}
	key := sha256.Sum256(shared)
	aead, _ := chacha20poly1305.New(key[:])
	nonce := make([]byte, 24)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	ct := aead.Seal(nil, nonce, plaintext, ephPub)
	payload := append(append(append([]byte{}, nonce...), ephPub...), ct...)
	return base64.StdEncoding.EncodeToString(payload), nil
}

// e2eOpen is the inverse of e2eSeal using the receiver's scalar.
func e2eOpen(scalar []byte, payloadBase64 string) ([]byte, error) {
	payload, err := base64.StdEncoding.DecodeString(payloadBase64)
	if err != nil {
		return nil, err
	}
	if len(payload) < 24+32+16 {
		return nil, fmt.Errorf("e2e payload too short")
	}
	nonce := payload[:24]
	ephPub := payload[24 : 24+32]
	ct := payload[24+32:]
	shared, err := curve25519.X25519(scalar, ephPub)
	if err != nil {
		return nil, err
	}
	key := sha256.Sum256(shared)
	aead, _ := chacha20poly1305.New(key[:])
	pt, err := aead.Open(nil, nonce, ct, ephPub)
	if err != nil {
		return nil, err
	}
	return pt, nil
}


func dial(configPath string) (*thin.ThinClient, error) {

// ---- end E2E helpers ----


	cfg, err := thin.LoadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}
	logging := &config.Logging{
		Disable: true,
		Level:   "ERROR",
	}
	client := thin.NewThinClient(cfg, logging)
	if err := client.Dial(); err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	return client, nil
}

func findChatService(client *thin.ThinClient) (*[32]byte, []byte, error) {
	for i := 0; i < 100; i++ {
		if client.PKIDocument() != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	for i := 0; i < 100; i++ {
		if client.PKIDocument() != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	doc := client.PKIDocument()
	if doc != nil {
		fmt.Printf("DEBUG findChatService: doc epoch %d service nodes %d\n", doc.Epoch, len(doc.ServiceNodes))
		for _, sn := range doc.ServiceNodes {
			fmt.Printf("DEBUG node %s caps %v\n", sn.Name, sn.Kaetzchen)
		}
	} else {
		fmt.Printf("DEBUG findChatService: no PKI doc\n")
	}
	for i := 0; i < 10; i++ {
		s, err := client.GetService("chat")
		if err == nil {
			h := blake2b.Sum256(s.MixDescriptor.IdentityKey)
			return &h, s.RecipientQueueID, nil
		}
		fmt.Printf("DEBUG GetService chat attempt %d failed: %v\n", i, err)
		time.Sleep(1 * time.Second)
	}
	return nil, nil, fmt.Errorf("chat service not found")
}

func sendRequest(client *thin.ThinClient, req ChatRequest) (ChatResponse, error) {
	destHash, queue, err := findChatService(client)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("service: %w", err)
	}
	payload, _ := cbor.Marshal(req)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	reply, err := client.BlockingSendMessage(ctx, payload, destHash, queue)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("send: %w", err)
	}
	var resp ChatResponse
	cbor.UnmarshalFirst(reply, &resp)
	return resp, nil
}

func decodeResponse(reply []byte) ChatResponse {
	var resp ChatResponse
	cbor.UnmarshalFirst(reply, &resp)
	return resp
}

// parseSendFlags pulls --via <netid> and --e2e out of args, leaving positionals.
func parseSendFlags(args []string) (rest []string, via string, e2e bool) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--via" && i+1 < len(args):
			via = args[i+1]
			i++
		case a == "--e2e":
			e2e = true
		default:
			rest = append(rest, a)
		}
	}
	return rest, via, e2e
}

func cmdSend(args []string) {
	rest, via, e2e := parseSendFlags(args)
	if len(rest) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat send <config.toml> [--via <netID>] [--e2e] <recipient_hex> <message>")
		os.Exit(1)
	}
	configPath, recipHex, message := rest[0], rest[1], rest[2]
	userID := getOrCreateID(configPath)
	recipBytes := parseRecipient(recipHex, userID)
	dir := cfgDirFor(configPath)

	// E2E sealing happens here (client-side), chatd + any bridge see ciphertext.
	if e2e {
		pub, ok := loadE2EPub(dir, recipHex)
		if !ok {
			fmt.Fprintf(os.Stderr, "no E2E key for %s — run: zkchat e2e-import %s %s <peerpub>\n", recipHex, configPath, recipHex)
			os.Exit(1)
		}
		sealed, err := e2eSeal(pub, []byte(message))
		if err != nil {
			fmt.Fprintf(os.Stderr, "e2e seal: %v\n", err)
			os.Exit(1)
		}
		message = sealed
	}

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	if via != "" {
		// cross-domain: hand an opaque relay envelope to the local +meshbridge
		resp, err := sendViaBridge(client, via, recipHex, message)
		if err != nil {
			fmt.Fprintf(os.Stderr, "bridge send failed: %v\n", err)
			os.Exit(1)
		}
		if resp.Success {
			fmt.Printf("Sent via bridge %s to %s (%s)\n", resp.Peer, recipHex, map[bool]string{true: "e2e", false: "cleartext"}[e2e])
		} else {
			fmt.Fprintf(os.Stderr, "bridge error: %s\n", resp.Error)
			os.Exit(1)
		}
		return
	}

	chatReq := ChatRequest{
		Op:        "send",
		UserID:    userID,
		Recipient: recipBytes,
		Content:   message,
		MsgType:   map[bool]string{true: "mesh-e2e", false: "text"}[e2e],
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "send failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Sent to %x", recipBytes)
		if e2e {
			fmt.Printf(" [e2e]")
		}
		if resp.Addr != "" {
			fmt.Printf(" [Autonomi: %s]", resp.Addr)
		}
		fmt.Println()
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

func cmdPoll(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat poll <config.toml>")
		os.Exit(1)
	}
	configPath := args[0]
	userID := getOrCreateID(configPath)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:     "poll",
		UserID: userID,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "poll failed: %v\n", err)
		os.Exit(1)
	}

	if !resp.Success {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if len(resp.Messages) == 0 {
		fmt.Println("No new messages.")
		return
	}

	for _, msg := range resp.Messages {
		ts := time.UnixMilli(msg.Timestamp)
		content, tag := msg.Content, msg.Type
		if msg.Type == "mesh-e2e" {
			dir := cfgDirFor(configPath)
			_, myPub := loadOrCreateE2EKeypair(dir)
			_ = myPub
			privPath := filepath.Join(dir, "e2e.keypair")
			raw, err := os.ReadFile(privPath)
			if err == nil && len(raw) >= 32 {
				if pt, derr := e2eOpen(raw[:32], msg.Content); derr == nil {
					content = string(pt)
				} else {
					content = "🔒 [unable to decrypt] " + msg.Content
				}
				tag = "e2e"
			} else {
				content = "🔒 [no e2e key on this client] " + msg.Content
				tag = "e2e-locked"
			}
		}
		fmt.Printf("[%s] from %x (%s):\n  %s\n",
			ts.Format("15:04:05"),
			msg.Sender,
			tag,
			content)
	}
}

func cmdAI(args []string) {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat ai <config.toml> <recipient_hex> <prompt>")
		os.Exit(1)
	}
	configPath, recipHex, prompt := args[0], args[1], args[2]
	userID := getOrCreateID(configPath)
	recipBytes := parseRecipient(recipHex, userID)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	destHash, queue, err := findChatService(client)
	if err != nil {
		fmt.Fprintf(os.Stderr, "service: %v\n", err)
		os.Exit(1)
	}

	chatReq := ChatRequest{
		Op:        "send",
		UserID:    userID,
		Recipient: recipBytes,
		Content:   prompt,
		MsgType:   "ai",
	}

	payload, _ := cbor.Marshal(chatReq)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	reply, err := client.BlockingSendMessage(ctx, payload, destHash, queue)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ai request failed: %v\n", err)
		os.Exit(1)
	}

	resp := decodeResponse(reply)
	if resp.Success {
		io.Copy(os.Stdout, bytes.NewReader([]byte(resp.Addr)))
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

// cmdE2EExport prints this client's identity + E2E public key for peers to import.
func cmdE2EExport(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat e2e-export <config.toml>")
		os.Exit(1)
	}
	configPath := args[0]
	dir := cfgDirFor(configPath)
	userID := getOrCreateID(configPath)
	_, pub := loadOrCreateE2EKeypair(dir)
	fmt.Printf("identity=%x pubkey=%x\n", userID, pub)
}

// cmdE2EImport stores a peer's E2E public key: zkchat e2e-import <cfg> <peerIdHex> <peerPubHex>
func cmdE2EImport(args []string) {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat e2e-import <config.toml> <peer_identity_hex> <peer_pub_hex>")
		os.Exit(1)
	}
	configPath, peerHex, pubHex := args[0], args[1], args[2]
	pub, err := hex.DecodeString(pubHex)
	if err != nil || len(pub) != 32 {
		fmt.Fprintln(os.Stderr, "peer pubkey must be 32-byte hex")
		os.Exit(1)
	}
	dir := cfgDirFor(configPath)
	if err := os.MkdirAll(filepath.Join(dir, "e2e-pubs"), 0700); err != nil {
		fmt.Fprintln(os.Stderr, "mkdir e2e-pubs:", err)
		os.Exit(1)
	}
	os.WriteFile(filepath.Join(dir, "e2e-pubs", peerHex+".pub"), pub, 0600)
	fmt.Printf("E2E key for %x stored\n", peerHex)
}

func groupCreate(args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group create <config.toml> <name> [member_hex...]")
		os.Exit(1)
	}
	configPath, name := args[0], args[1]
	userID := getOrCreateID(configPath)

	var members [][]byte
	for _, m := range args[2:] {
		b, err := hex.DecodeString(m)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid member hex: %s\n", m)
			os.Exit(1)
		}
		if len(b) != 16 {
			fmt.Fprintln(os.Stderr, "member must be 16 bytes (32 hex chars)")
			os.Exit(1)
		}
		members = append(members, b)
	}

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:        "group_create",
		UserID:    userID,
		GroupName: name,
		Members:   members,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group create failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Created group %q with ID: %s\n", name, resp.GroupID)
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

func groupSend(args []string) {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group send <config.toml> <group_id> <message>")
		os.Exit(1)
	}
	configPath, groupID, message := args[0], args[1], args[2]
	userID := getOrCreateID(configPath)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:      "group_send",
		UserID:  userID,
		GroupID: groupID,
		Content: message,
		MsgType: "text",
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group send failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Sent to group %s", groupID)
		if resp.Addr != "" {
			fmt.Printf(" [Autonomi: %s]", resp.Addr)
		}
		fmt.Println()
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

func groupPoll(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group poll <config.toml> [group_id]")
		os.Exit(1)
	}
	configPath := args[0]
	userID := getOrCreateID(configPath)

	groupID := ""
	if len(args) > 1 {
		groupID = args[1]
	}

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:      "group_poll",
		UserID:  userID,
		GroupID: groupID,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group poll failed: %v\n", err)
		os.Exit(1)
	}

	if !resp.Success {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if len(resp.Messages) == 0 {
		fmt.Println("No new group messages.")
		return
	}

	for _, msg := range resp.Messages {
		ts := time.UnixMilli(msg.Timestamp)
		gid := msg.GroupID
		if len(gid) > 8 {
			gid = gid[:8] + "..."
		}
		fmt.Printf("[%s] [%s] from %x (%s):\n  %s\n",
			ts.Format("15:04:05"),
			gid,
			msg.Sender,
			msg.Type,
			msg.Content)
	}
}

func groupInvite(args []string) {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group invite <config.toml> <group_id> <member_hex> [member_hex...]")
		os.Exit(1)
	}
	configPath, groupID := args[0], args[1]
	userID := getOrCreateID(configPath)

	var members [][]byte
	for _, m := range args[2:] {
		b, err := hex.DecodeString(m)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid member hex: %s\n", m)
			os.Exit(1)
		}
		if len(b) != 16 {
			fmt.Fprintln(os.Stderr, "member must be 16 bytes (32 hex chars)")
			os.Exit(1)
		}
		members = append(members, b)
	}

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:      "group_invite",
		UserID:  userID,
		GroupID: groupID,
		Members: members,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group invite failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Added %d member(s) to group %s\n", len(members), groupID)
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

func groupLeave(args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group leave <config.toml> <group_id>")
		os.Exit(1)
	}
	configPath, groupID := args[0], args[1]
	userID := getOrCreateID(configPath)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:      "group_leave",
		UserID:  userID,
		GroupID: groupID,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group leave failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Left group %s\n", groupID)
	} else {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}
}

func groupList(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat group list <config.toml>")
		os.Exit(1)
	}
	configPath := args[0]
	userID := getOrCreateID(configPath)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:     "group_list",
		UserID: userID,
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "group list failed: %v\n", err)
		os.Exit(1)
	}

	if !resp.Success {
		fmt.Fprintf(os.Stderr, "Error: %s\n", resp.Error)
		os.Exit(1)
	}

	if len(resp.Groups) == 0 {
		fmt.Println("No groups.")
		return
	}

	for _, g := range resp.Groups {
		fmt.Printf("  %s  %s  (%d members)\n", g.ID[:8], g.Name, len(g.Members))
	}
}

func getOrCreateID(configPath string) []byte {
	dir := filepath.Dir(configPath)
	id, err := loadOrCreateIdentity(filepath.Join(dir, ".zkchat"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "identity: %v\n", err)
		os.Exit(1)
	}
	return id
}

func parseRecipient(s string, self []byte) []byte {
	if s == "self" {
		return self
	}
	if b, err := hex.DecodeString(s); err == nil {
		if len(b) != 16 {
			fmt.Fprintln(os.Stderr, "recipient must be 16 bytes (32 hex chars)")
			os.Exit(1)
		}
		return b
	}
	h := blake2b.Sum256([]byte(s))
	return h[:16]
}
