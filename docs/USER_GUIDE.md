# Connect to a zknode — Simple Guide

This is the 5-minute version. You do **not** need an account, a wallet, or any
cloud service. You join a private network (Tailscale), open a dashboard in your
browser, and chat.

> **Testnet only.** Not audited, not production. Messages are private in transit
> but stored in plaintext on the chat server. Do not send secrets.

---

## How it works

Two sovereign zknodes sit on a private, encrypted Tailscale network. You join
that network from your phone or laptop, then talk to either node's dashboard.
Chat messages travel through each island's own post-quantum mixnet; a bridge
relays messages between the two islands.

```
                        PRIVATE TAILSCALE NETWORK (WireGuard, invite-only)
                        ┌──────────────────────────────────────────────┐
                        │                                              │
   You (phone/laptop)   │   ┌────────────────────┐  ┌───────────────┐  │
   ┌──────────────┐     │   │  zknode "box"      │  │ zknode "SCM4" │  │
   │ Browser      │     │   │  100.66.60.127     │  │ 100.75.15.108 │  │
   │  └ dashboard │◄────┼──►│  :8080 dashboard   │  │ :8080 dash    │  │
   │  └ zkchat    │     │   │  :31008 gateway    │◄►│ :31007 gateway│  │
   │  └ /ai ZeroAI│     │   │  mixnet + ZeroAI   │  │ mixnet + wiki │  │
   └──────────────┘     │   └────────────────────┘  └───────────────┘  │
                        │        ▲        mesh bridge (relay)   ▲      │
                        └────────┼───────────────────────────────┼─────┘
                                 │                               │
                    each island mixes + re-encrypts traffic in 3 hops;
                    the bridge forwards a DM to the other island's +chat
```

**What a message does:**

```
your browser ──► dashboard/zkchat ──► mixnet (3 hops) ──► +chat on the node
                                                            │
       /ai question ──► ZeroAI (local LLM) ──► answer back in the group
```

**Cross-island (bridge) path:**

```
zkchat A ──► +meshbridge A ──► relay ──► gateway B ──► mixnet B ──► +chat B ──► zkchat B
```

---

## Step 1 — Install Tailscale

| Device | How |
|---|---|
| iPhone / iPad | App Store → **Tailscale** |
| Android | Play Store → **Tailscale** |
| macOS | [tailscale.com/download](https://tailscale.com/download) (or Mac App Store) |
| Windows | [tailscale.com/download](https://tailscale.com/download) |
| Linux | `curl -fsSL https://tailscale.com/install.sh \| sh` |

Then open Tailscale and sign in when prompted.

## Step 2 — Join the private network

1. Ask the zknode operator for a **Tailscale invite link** (or an auth key).
2. Open the link and approve your device.
3. Confirm you can see the nodes:

```bash
tailscale status
# should list:  zknode-0kn-a   and   zknode-01
tailscale ping zknode-0kn-a
```

If you only have the phone app, the node list is shown on the Tailscale main
screen and in the admin console.

## Step 3 — Open a dashboard

Open one of these **while Tailscale is connected**:

| Node | URL |
|---|---|
| Box | **http://100.66.60.127:8080** |
| SCM4 | **http://100.75.15.108:8080** |

- If the page asks for a **token**, ask the operator. Tokens are intentionally
  not published in this repository.
- You should see a green **healthy** status. If not, see Troubleshooting.

> The operator may give you different tailnet addresses; use the ones they send.

## Step 4 — Chat and ZeroAI

1. Open the **zkchat** / **Chat** panel.
2. Pick an existing group, or create one.
3. Type a message and send.

Notes:
- Messages are deliberately delayed by the mixnet: **~20–40 seconds** is normal.
- Group polls can take a little longer; refresh after a minute.
- Ask the AI inside a group by starting the message with `/ai`:

```
/ai explain a mixnet in one sentence
```

ZeroAI runs on the node (local model), not in the cloud. A reply usually
arrives in 1–2 minutes:

```
[ai] A mixnet is a system that mixes and anonymizes messages from multiple
     senders to obscure the origin and destination of any single message.
```

## Step 5 — Verify

| Check | Expected |
|---|---|
| `tailscale status` | nodes listed, not “offline” |
| Dashboard header | **healthy** |
| Send a chat message | appears after ~20–40 s |
| Send `/ai hello` | `[ai] thinking...` then a reply |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Page does not load | Tailscale is off, or wrong address. Connect Tailscale first. |
| “Unauthorized” / token prompt | Ask the operator for the dashboard token. |
| Chat says “mixnet unavailable” | Node’s client daemon is starting. Wait 30 s and retry. |
| Message never appears | Normal delay is up to ~40 s; refresh the group. |
| `/ai` gives an error | The local model is loading (first call can take ~1 min). Retry. |
| Everything is slow | The mixnet adds privacy delays by design; this is expected. |

## Privacy and safety

- The network is **invite-only**; nothing is exposed to the public internet.
- Do **not** share your Tailscale auth key or dashboard token.
- Treat this as a testnet: no sensitive data, no guarantees, keys may rotate.
- Messages are private in transit (mixnet) and in storage on the node’s chat
  server; the bridge sees cross-island messages while relaying them.

---

For operators bringing up or connecting a new node, see
[OPERATOR_QUICKSTART.md](OPERATOR_QUICKSTART.md).
