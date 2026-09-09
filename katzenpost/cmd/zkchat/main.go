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
	"golang.org/x/crypto/blake2b"

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
  send <config.toml> <recipient_hex> <message>
    Send a chat message to recipient.

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

func dial(configPath string) (*thin.ThinClient, error) {
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

func cmdSend(args []string) {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "Usage: zkchat send <config.toml> <recipient_hex> <message>")
		os.Exit(1)
	}
	configPath, recipHex, message := args[0], args[1], args[2]
	userID := getOrCreateID(configPath)
	recipBytes := parseRecipient(recipHex, userID)

	client, err := dial(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	chatReq := ChatRequest{
		Op:        "send",
		UserID:    userID,
		Recipient: recipBytes,
		Content:   message,
		MsgType:   "text",
	}

	resp, err := sendRequest(client, chatReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "send failed: %v\n", err)
		os.Exit(1)
	}

	if resp.Success {
		fmt.Printf("Sent to %x", recipBytes)
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
		fmt.Printf("[%s] from %x (%s):\n  %s\n",
			ts.Format("15:04:05"),
			msg.Sender,
			msg.Type,
			msg.Content)
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
