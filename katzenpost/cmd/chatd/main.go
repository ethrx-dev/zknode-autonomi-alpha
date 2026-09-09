package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sync"
	"time"

	"github.com/carlmjohnson/versioninfo"
	cbor "github.com/fxamacker/cbor/v2"
	"gopkg.in/op/go-logging.v1"

	"github.com/katzenpost/katzenpost/core/log"
	"github.com/katzenpost/katzenpost/server/cborplugin"
)

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

type ChatResponse struct {
	Success  bool          `cbor:"success"`
	Error    string        `cbor:"error,omitempty"`
	Messages []ChatMessage `cbor:"messages,omitempty"`
	Addr     string        `cbor:"addr,omitempty"`
	GroupID  string        `cbor:"group_id,omitempty"`
	Groups   []Group       `cbor:"groups,omitempty"`
}

type Chatd struct {
	log        *logging.Logger
	write      func(cborplugin.Command)
	storeDir   string
	antPath    string
	useAnt     bool
	faeAddress string
	faeModel   string
	mu         sync.Mutex
}

func (c *Chatd) OnCommand(cmd cborplugin.Command) error {
	switch r := cmd.(type) {
	case *cborplugin.Request:
		go func() {
			resp := c.process(r)
			c.write(&cborplugin.Response{ID: r.ID, SURB: r.SURB, Payload: resp})
		}()
		return nil
	default:
		return errors.New("chatd: invalid command type")
	}
}

func (c *Chatd) RegisterConsumer(s *cborplugin.Server) {
	c.write = s.Write
}

func (c *Chatd) process(req *cborplugin.Request) []byte {
	var chatReq ChatRequest
	dec := cbor.NewDecoder(bytes.NewReader(req.Payload))
	if err := dec.Decode(&chatReq); err != nil {
		return mustMarshal(ChatResponse{Error: fmt.Sprintf("decode: %v", err)})
	}

	switch chatReq.Op {
	case "send":
		if chatReq.MsgType == "ai" && c.faeAddress != "" {
			return mustMarshal(c.handleAI(chatReq))
		}
		return mustMarshal(c.handleSend(chatReq))
	case "poll":
		return mustMarshal(c.handlePoll(chatReq))
	case "group_create":
		return mustMarshal(c.handleGroupCreate(chatReq))
	case "group_send":
		return mustMarshal(c.handleGroupSend(chatReq))
	case "group_poll":
		return mustMarshal(c.handleGroupPoll(chatReq))
	case "group_invite":
		return mustMarshal(c.handleGroupInvite(chatReq))
	case "group_leave":
		return mustMarshal(c.handleGroupLeave(chatReq))
	case "group_list":
		return mustMarshal(c.handleGroupList(chatReq))
	default:
		return mustMarshal(ChatResponse{Error: fmt.Sprintf("unknown op: %s", chatReq.Op)})
	}
}

func (c *Chatd) handleSend(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}
	if req.Content == "" {
		return ChatResponse{Error: "content required"}
	}

	msg := ChatMessage{
		ID:        newID(),
		Sender:    req.UserID,
		Content:   req.Content,
		Type:      req.MsgType,
		Timestamp: time.Now().UnixMilli(),
	}

	recipient := req.Recipient
	if len(recipient) == 0 {
		recipient = req.UserID
	}

	userDir := filepath.Join(c.storeDir, "user_"+hex.EncodeToString(recipient))
	if err := os.MkdirAll(userDir, 0700); err != nil {
		return ChatResponse{Error: fmt.Sprintf("mkdir: %v", err)}
	}

	path := filepath.Join(userDir, msg.ID+".msg")
	blob, _ := cbor.Marshal(msg)
	if err := os.WriteFile(path, blob, 0600); err != nil {
		return ChatResponse{Error: fmt.Sprintf("write: %v", err)}
	}

	c.log.Debugf("stored DM %s for user %x", msg.ID, recipient)

	if c.useAnt {
		addr, err := c.storeAnt(blob)
		if err != nil {
			c.log.Warningf("ant store failed: %v", err)
		} else {
			os.Remove(path)
			return ChatResponse{Success: true, Addr: addr}
		}
	}

	return ChatResponse{Success: true}
}

func (c *Chatd) handleAI(req ChatRequest) ChatResponse {
	if req.Content == "" {
		return ChatResponse{Error: "content required"}
	}

	body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"system","content":"You are a helpful AI assistant. Reply concisely and accurately."},{"role":"user","content":%s}],"max_tokens":1024,"temperature":0.7}`,
		c.faeModel, mustJSONString(req.Content))

	resp, err := http.Post("http://"+c.faeAddress+"/v1/chat/completions", "application/json", bytes.NewReader([]byte(body)))
	if err != nil {
		return ChatResponse{Error: fmt.Sprintf("fae request: %v", err)}
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return ChatResponse{Error: fmt.Sprintf("fae response: %v", err)}
	}

	return ChatResponse{Success: true, Addr: string(respBody)}
}

func (c *Chatd) handlePoll(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}

	userDir := filepath.Join(c.storeDir, "user_"+hex.EncodeToString(req.UserID))
	entries, err := os.ReadDir(userDir)
	if err != nil {
		if os.IsNotExist(err) {
			return ChatResponse{Success: true, Messages: []ChatMessage{}}
		}
		return ChatResponse{Error: fmt.Sprintf("readdir: %v", err)}
	}

	var msgs []ChatMessage
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".msg" {
			continue
		}
		blob, err := os.ReadFile(filepath.Join(userDir, e.Name()))
		if err != nil {
			continue
		}
		var msg ChatMessage
		if err := cbor.Unmarshal(blob, &msg); err != nil {
			continue
		}
		msgs = append(msgs, msg)
		os.Remove(filepath.Join(userDir, e.Name()))
	}

	c.log.Debugf("polled %d DMs for user %x", len(msgs), req.UserID)
	return ChatResponse{Success: true, Messages: msgs}
}

func (c *Chatd) handleGroupCreate(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}
	if req.GroupName == "" {
		return ChatResponse{Error: "group_name required"}
	}

	groupID := newID()
	now := time.Now().UnixMilli()

	members := [][]byte{req.UserID}
	members = append(members, req.Members...)

	g := Group{
		ID:        groupID,
		Name:      req.GroupName,
		Owner:     req.UserID,
		Members:   members,
		CreatedAt: now,
	}

	groupDir := filepath.Join(c.storeDir, "group_"+groupID)
	if err := os.MkdirAll(groupDir, 0700); err != nil {
		return ChatResponse{Error: fmt.Sprintf("mkdir: %v", err)}
	}

	if err := c.writeGroupMeta(groupID, &g); err != nil {
		return ChatResponse{Error: fmt.Sprintf("write meta: %v", err)}
	}

	for _, m := range members {
		if err := c.addUserGroup(m, groupID); err != nil {
			c.log.Warningf("add user %x to group %s: %v", m, groupID, err)
		}
	}

	c.log.Debugf("created group %s (%s) with %d members", groupID, req.GroupName, len(members))
	return ChatResponse{Success: true, GroupID: groupID}
}

func (c *Chatd) handleGroupSend(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}
	if req.GroupID == "" {
		return ChatResponse{Error: "group_id required"}
	}
	if req.Content == "" {
		return ChatResponse{Error: "content required"}
	}

	g, err := c.loadGroupMeta(req.GroupID)
	if err != nil {
		return ChatResponse{Error: fmt.Sprintf("group not found: %v", err)}
	}

	if !c.isMember(g, req.UserID) {
		return ChatResponse{Error: "not a group member"}
	}

	msg := ChatMessage{
		ID:        newID(),
		Sender:    req.UserID,
		Content:   req.Content,
		Type:      req.MsgType,
		Timestamp: time.Now().UnixMilli(),
		GroupID:   req.GroupID,
	}

	groupDir := filepath.Join(c.storeDir, "group_"+req.GroupID)
	if err := os.MkdirAll(groupDir, 0700); err != nil {
		return ChatResponse{Error: fmt.Sprintf("mkdir: %v", err)}
	}

	path := filepath.Join(groupDir, msg.ID+".msg")
	blob, _ := cbor.Marshal(msg)
	if err := os.WriteFile(path, blob, 0600); err != nil {
		return ChatResponse{Error: fmt.Sprintf("write: %v", err)}
	}

	c.log.Debugf("stored group message %s in group %s from user %x", msg.ID, req.GroupID, req.UserID)

	if c.useAnt {
		addr, err := c.storeAnt(blob)
		if err != nil {
			c.log.Warningf("ant store failed: %v", err)
		} else {
			return ChatResponse{Success: true, Addr: addr}
		}
	}

	if req.MsgType == "ai" && c.faeAddress != "" {
		go c.processGroupAI(req, groupDir)
	}

	return ChatResponse{Success: true}
}

func (c *Chatd) processGroupAI(req ChatRequest, groupDir string) {
	body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"system","content":"You are a helpful AI assistant. Reply concisely and accurately."},{"role":"user","content":%s}],"max_tokens":1024,"temperature":0.7}`,
		c.faeModel, mustJSONString(req.Content))

	resp, err := http.Post("http://"+c.faeAddress+"/v1/chat/completions", "application/json", bytes.NewReader([]byte(body)))
	if err != nil {
		c.log.Errorf("group AI request failed: %v", err)
		return
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		c.log.Errorf("group AI response read failed: %v", err)
		return
	}

	var aiResp struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(respBody, &aiResp); err != nil {
		c.log.Errorf("group AI response parse failed: %v", err)
		return
	}

	if len(aiResp.Choices) == 0 {
		c.log.Error("group AI returned no choices")
		return
	}

	aiMsg := ChatMessage{
		ID:        newID(),
		Sender:    []byte{},
		Content:   aiResp.Choices[0].Message.Content,
		Type:      "ai_response",
		Timestamp: time.Now().UnixMilli(),
		GroupID:   req.GroupID,
	}

	aiBlob, _ := cbor.Marshal(aiMsg)
	aiPath := filepath.Join(groupDir, aiMsg.ID+".msg")
	if err := os.WriteFile(aiPath, aiBlob, 0600); err != nil {
		c.log.Errorf("group AI store failed: %v", err)
		return
	}

	c.log.Debugf("AI response stored as message %s in group %s", aiMsg.ID, req.GroupID)
}

func (c *Chatd) handleGroupPoll(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}

	var groupIDs []string

	if req.GroupID != "" {
		g, err := c.loadGroupMeta(req.GroupID)
		if err != nil {
			return ChatResponse{Error: fmt.Sprintf("group not found: %v", err)}
		}
		if !c.isMember(g, req.UserID) {
			return ChatResponse{Error: "not a group member"}
		}
		groupIDs = []string{req.GroupID}
	} else {
		var err error
		groupIDs, err = c.getUserGroups(req.UserID)
		if err != nil {
			groupIDs = []string{}
		}
	}

	var allMsgs []ChatMessage
	for _, gid := range groupIDs {
		gDir := filepath.Join(c.storeDir, "group_"+gid)
		entries, err := os.ReadDir(gDir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			c.log.Warningf("read group dir %s: %v", gid, err)
			continue
		}
		for _, e := range entries {
			if filepath.Ext(e.Name()) != ".msg" {
				continue
			}
			blob, err := os.ReadFile(filepath.Join(gDir, e.Name()))
			if err != nil {
				continue
			}
			var msg ChatMessage
			if err := cbor.Unmarshal(blob, &msg); err != nil {
				continue
			}
			allMsgs = append(allMsgs, msg)
			os.Remove(filepath.Join(gDir, e.Name()))
		}
	}

	c.log.Debugf("group poll: %d messages for user %x from %d groups", len(allMsgs), req.UserID, len(groupIDs))
	return ChatResponse{Success: true, Messages: allMsgs}
}

func (c *Chatd) handleGroupInvite(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}
	if req.GroupID == "" {
		return ChatResponse{Error: "group_id required"}
	}
	if len(req.Members) == 0 {
		return ChatResponse{Error: "members required"}
	}

	g, err := c.loadGroupMeta(req.GroupID)
	if err != nil {
		return ChatResponse{Error: fmt.Sprintf("group not found: %v", err)}
	}

	if !bytes.Equal(g.Owner, req.UserID) {
		return ChatResponse{Error: "only the group owner can invite members"}
	}

	existing := make(map[string]bool)
	for _, m := range g.Members {
		existing[hex.EncodeToString(m)] = true
	}

	for _, m := range req.Members {
		if !existing[hex.EncodeToString(m)] {
			g.Members = append(g.Members, m)
			existing[hex.EncodeToString(m)] = true
		}
	}

	if err := c.writeGroupMeta(req.GroupID, g); err != nil {
		return ChatResponse{Error: fmt.Sprintf("write meta: %v", err)}
	}

	for _, m := range req.Members {
		if err := c.addUserGroup(m, req.GroupID); err != nil {
			c.log.Warningf("add user %x to group %s: %v", m, req.GroupID, err)
		}
	}

	c.log.Debugf("added %d members to group %s", len(req.Members), req.GroupID)
	return ChatResponse{Success: true}
}

func (c *Chatd) handleGroupLeave(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}
	if req.GroupID == "" {
		return ChatResponse{Error: "group_id required"}
	}

	g, err := c.loadGroupMeta(req.GroupID)
	if err != nil {
		return ChatResponse{Error: fmt.Sprintf("group not found: %v", err)}
	}

	filtered := make([][]byte, 0, len(g.Members))
	for _, m := range g.Members {
		if !bytes.Equal(m, req.UserID) {
			filtered = append(filtered, m)
		}
	}
	g.Members = filtered

	if len(g.Members) == 0 {
		os.RemoveAll(filepath.Join(c.storeDir, "group_"+req.GroupID))
	} else {
		if bytes.Equal(g.Owner, req.UserID) && len(g.Members) > 0 {
			g.Owner = g.Members[0]
		}
		if err := c.writeGroupMeta(req.GroupID, g); err != nil {
			return ChatResponse{Error: fmt.Sprintf("write meta: %v", err)}
		}
	}

	c.removeUserGroup(req.UserID, req.GroupID)

	c.log.Debugf("user %x left group %s", req.UserID, req.GroupID)
	return ChatResponse{Success: true}
}

func (c *Chatd) handleGroupList(req ChatRequest) ChatResponse {
	if len(req.UserID) == 0 {
		return ChatResponse{Error: "user_id required"}
	}

	groupIDs, err := c.getUserGroups(req.UserID)
	if err != nil {
		return ChatResponse{Success: true, Groups: []Group{}}
	}

	var groups []Group
	for _, gid := range groupIDs {
		g, err := c.loadGroupMeta(gid)
		if err != nil {
			c.log.Warningf("load group %s: %v", gid, err)
			continue
		}
		groups = append(groups, *g)
	}

	c.log.Debugf("listed %d groups for user %x", len(groups), req.UserID)
	return ChatResponse{Success: true, Groups: groups}
}

func (c *Chatd) loadGroupMeta(groupID string) (*Group, error) {
	path := filepath.Join(c.storeDir, "group_"+groupID, "meta.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var g Group
	if err := json.Unmarshal(b, &g); err != nil {
		return nil, err
	}
	return &g, nil
}

func (c *Chatd) writeGroupMeta(groupID string, g *Group) error {
	dir := filepath.Join(c.storeDir, "group_"+groupID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	b, err := json.Marshal(g)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "meta.json"), b, 0600)
}

func (c *Chatd) getUserGroups(userID []byte) ([]string, error) {
	path := filepath.Join(c.storeDir, "user_"+hex.EncodeToString(userID), "groups.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var groups []string
	if err := json.Unmarshal(b, &groups); err != nil {
		return nil, err
	}
	return groups, nil
}

func (c *Chatd) addUserGroup(userID []byte, groupID string) error {
	groups, err := c.getUserGroups(userID)
	if err != nil {
		groups = []string{}
	}

	for _, g := range groups {
		if g == groupID {
			return nil
		}
	}

	groups = append(groups, groupID)
	userDir := filepath.Join(c.storeDir, "user_"+hex.EncodeToString(userID))
	if err := os.MkdirAll(userDir, 0700); err != nil {
		return err
	}
	b, _ := json.Marshal(groups)
	return os.WriteFile(filepath.Join(userDir, "groups.json"), b, 0600)
}

func (c *Chatd) removeUserGroup(userID []byte, groupID string) error {
	groups, err := c.getUserGroups(userID)
	if err != nil {
		return nil
	}
	filtered := make([]string, 0, len(groups))
	for _, g := range groups {
		if g != groupID {
			filtered = append(filtered, g)
		}
	}
	b, _ := json.Marshal(filtered)
	return os.WriteFile(filepath.Join(c.storeDir, "user_"+hex.EncodeToString(userID), "groups.json"), b, 0600)
}

func (c *Chatd) isMember(g *Group, userID []byte) bool {
	for _, m := range g.Members {
		if bytes.Equal(m, userID) {
			return true
		}
	}
	return false
}

func (c *Chatd) storeAnt(data []byte) (string, error) {
	cmd := exec.Command(c.antPath, "--json", "chunk", "put")
	cmd.Stdin = bytes.NewReader(data)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes.TrimSpace(out.Bytes())), nil
}

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func mustMarshal(v interface{}) []byte {
	b, err := cbor.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func mustJSONString(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		return "\"\""
	}
	return string(b)
}

func main() {
	var logLevel string
	var logDir string
	var storeDir string
	var antPath string
	var faeAddress string
	var faeModel string
	flag.StringVar(&logDir, "log_dir", "", "logging directory")
	flag.StringVar(&logLevel, "log_level", "DEBUG", "logging level")
	flag.StringVar(&storeDir, "store", "/tmp/zkchat", "message store directory")
	flag.StringVar(&antPath, "ant_path", "/home/<username>/.local/bin/ant", "autonomi ant CLI path")
	flag.StringVar(&faeAddress, "fae_address", "", "FAE AI inference server address (host:port)")
	flag.StringVar(&faeModel, "fae_model", "phi-3-mini-q4", "FAE AI model name")
	flag.Parse()

	if logDir == "" {
		tmpDir, err := os.MkdirTemp("", "chatd")
		if err != nil {
			panic(err)
		}
		logDir = tmpDir
	}

	s, err := os.Stat(logDir)
	if os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "Log directory '%s' doesn't exist.\n", logDir)
		os.Exit(1)
	}
	if !s.IsDir() {
		fmt.Fprintln(os.Stderr, "Log directory must be a directory.")
		os.Exit(1)
	}

	if err := os.MkdirAll(storeDir, 0700); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create store dir: %v\n", err)
		os.Exit(1)
	}

	logFile := path.Join(logDir, fmt.Sprintf("chatd.%d.log", os.Getpid()))
	logBackend, err := log.New(logFile, logLevel, false)
	if err != nil {
		panic(err)
	}
	serverLog := logBackend.GetLogger("chatd")
	serverLog.Noticef("chatd version: %s", versioninfo.Short())

	tmpDir, err := os.MkdirTemp("", "chatd")
	if err != nil {
		panic(err)
	}
	socketFile := filepath.Join(tmpDir, fmt.Sprintf("%d.chatd.socket", os.Getpid()))

	useAnt := false
	if _, err := os.Stat(antPath); err == nil {
		if err := exec.Command(antPath, "node", "status").Run(); err == nil {
			useAnt = true
			serverLog.Noticef("Autonomi storage enabled via %s", antPath)
		}
	}
	if !useAnt {
		serverLog.Noticef("Autonomi not available, using local storage: %s", storeDir)
	}

	p := &Chatd{
		log:        serverLog,
		storeDir:   storeDir,
		antPath:    antPath,
		useAnt:     useAnt,
		faeAddress: faeAddress,
		faeModel:   faeModel,
	}

	server := cborplugin.NewServer(serverLog, socketFile, new(cborplugin.RequestFactory), p)
	fmt.Println(socketFile)
	server.Accept()
	server.Wait()
	os.Remove(socketFile)
}
