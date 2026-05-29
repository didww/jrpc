# JRPC

A JSON-RPC 2.0 client for Ruby, over TCP, with netstring framing.

JRPC ships two clients with sharp, separate responsibilities:

| | `JRPC::SimpleClient` | `JRPC::SharedClient` |
|---|---|---|
| Concurrency | single thread/fiber only | shared across many threads **and/or** fibers |
| Connection | one socket, lazy connect | one shared socket, dedicated transport thread |
| Multiplexing | one in-flight call at a time | many in-flight calls, id-demuxed |
| Timeouts | per-call `read_timeout`/`write_timeout` | per-message `ttl` |
| Use it for | CLI tools, scripts, one-shot calls, per-thread pools | Rails+Puma, rage-rb, Falcon, any long-lived shared client |

Pick `SimpleClient` unless you need one client instance to serve concurrent callers. It is not thread-safe or fiber-safe; use one instance per thread/fiber (or a pool). Pick `SharedClient` when a single process-wide instance must serve many caller threads or fibers over a single connection.

## Installation

```ruby
gem 'jrpc'
```

```sh
$ bundle install
```

Requires **Ruby >= 3.3**. Fiber callers additionally require a spec-compliant `Fiber.scheduler` (e.g. [`async`](https://github.com/socketry/async)) on their thread — see [Fiber callers](#fiber-callers).

## SimpleClient

```ruby
client = JRPC::SimpleClient.new(
  "127.0.0.1:1234",
  connect_timeout:     60,    # total wall-clock budget for connect, across retries (seconds)
  read_timeout:        60,
  write_timeout:       60,
  connect_retry_count: 0,     # retries after the first failed connect
  autoclose:           false, # close the socket after every call
  id_prefix:           nil,   # random per instance if nil
  tcp_md5_pass:        nil,   # RFC2385 TCP MD5 Signature key (Linux-only); nil disables
  logger:              nil
)

result = client.request(:sum, [1, 2])
result = client.request(:sum, [1, 2], read_timeout: 10, write_timeout: 10)
client.notification(:log, { msg: "hi" })
client.notification(:log, { msg: "hi" }, write_timeout: 10)

client.close      # terminal; the instance cannot be reused
client.closed?    # => true
client.server     # => "127.0.0.1:1234"
```

Behavior:

- The constructor does **not** open the connection. The first `request`/`notification` connects.
- `autoclose: true` closes the socket in an `ensure` after each call. The **client is still reusable** — the next call reconnects. `autoclose` controls the socket, not the client.
- `#close` is **terminal**. After it, `#closed?` is `true` and every call raises `ClientError("client closed")`. There is no reopen — make a new client.
- Not thread-safe, not fiber-safe.

## SharedClient

One instance, one connection, many concurrent callers. A dedicated transport thread owns the socket and demultiplexes responses by id.

```ruby
client = JRPC::SharedClient.new(
  "127.0.0.1:1234",
  connect_timeout:        60,
  connect_retry_count:    0,
  connect_retry_interval: 0.5,
  write_timeout:          5,      # MUST be < default_ttl (see below)
  reap_timeout:           nil,    # nil = never close an idle connection
  default_ttl:            30,     # per-message lifetime, seconds
  max_queue_size:         10_000, # bounded; pass nil for unbounded (opt-in OOM risk)
  id_prefix:              nil,
  tcp_md5_pass:           nil,    # RFC2385 TCP MD5 Signature key (Linux-only); nil disables
  logger:                 nil
)

result = client.request(:sum, [1, 2])
result = client.request(:sum, [1, 2], ttl: 10)

client.notification(:log, { msg: "hi" })
client.notification(:log, { msg: "hi" }, ttl: 5)
client.notification(:metric, [1], fire_and_forget: true) # send errors/TTL expiry are logged, not raised

client.close              # graceful shutdown, default timeout: 5 seconds
client.close(timeout: 10)
client.closed?
client.server
```

Behavior:

- **TTL, not per-call timeout.** Each message carries `expires_at = now + ttl`. The transport thread is the timer authority; the caller blocks until the message resolves, fails, or its TTL elapses. `ttl: nil` blocks forever (opt-in).
- **`write_timeout < default_ttl` is enforced.** While the transport thread is parked in a single `write_frame`, it cannot fire TTL deadlines for other messages, so `write_timeout` is the maximum TTL-firing lag. The constructor raises `ArgumentError` if `write_timeout >= default_ttl`.
- **`notification` blocks until sent by default** (send errors propagate). Pass `fire_and_forget: true` to return immediately; then send errors and TTL expiry are logged, not raised. `request` never accepts `fire_and_forget`.
- **Bounded queue.** When the outbound queue is at `max_queue_size`, enqueue raises `ClientError("queue full")`.
- **Connection drops** resolve every in-flight request with `ConnectionError`; the transport thread keeps running and reconnects on the next message.
- **Reaping.** With `reap_timeout` set, the connection closes after that many idle seconds (no in-flight messages, empty queue, no bytes received) and reopens on the next message.
- `#close` is graceful: it lets in-flight work drain up to `timeout`, then force-closes. It returns `true` on a clean join, `false` on a forced close. Idempotent.
- A crash in the transport thread is surfaced, not hidden: in-flight requests fail with `ConnectionError`, the client transitions to an unusable state, and every subsequent call raises `ClientError("client unusable: transport thread exited")`. The client does not auto-restart — instantiate a new one.

### Fiber callers

`SharedClient` is shareable across the full Ruby concurrency matrix:

| Deployment | Caller is a... |
|---|---|
| Rails + Puma | Thread |
| rage-rb | Fiber under a single-thread Async reactor |
| Rails + Falcon | Fiber under a multi-thread Async reactor |
| Mixed | Some threads, some fibers, one client instance |

A caller blocks in a scheduler-aware wait, so a fiber under `Async`/`Falcon`/`rage-rb` **yields to the reactor** instead of stalling its OS thread; other fibers keep running and the response is routed back to the right fiber. This requires:

- Ruby **>= 3.3** (where the `ConditionVariable` ↔ `Fiber.scheduler` cooperation is verified), and
- a spec-compliant `Fiber.scheduler` active on the caller's thread, with correct cross-thread `unblock` (Async and Polyphony qualify).

No scheduler library is a runtime dependency — callers bring their own. Plain (non-scheduler) fibers are unsupported: they would block the OS thread on every wait. Use `SimpleClient` for non-scheduler code.

## Errors

All errors live under `JRPC::Errors::*` and descend from `JRPC::Errors::Error`. The four public-facing classes are siblings (no inheritance between them), so rescue each by name or rescue `Errors::Error` to catch all:

```
Errors::Error (RuntimeError)
├── Errors::ClientError          # caller-side: bad args, bad URI, client closed, queue full
├── Errors::ConnectionError      # cannot connect, or connection died (see Exception#cause)
├── Errors::Timeout              # message TTL elapsed, or SimpleClient read/write/connect timeout
└── Errors::ServerError          # peer returned an error, or the response was unusable
       attr_reader :code         # nil for malformed responses
       ├── Errors::ParseError              # -32700
       ├── Errors::InvalidRequest          # -32600
       ├── Errors::MethodNotFound          # -32601
       ├── Errors::InvalidParams           # -32602
       ├── Errors::InternalError           # -32603
       ├── Errors::InternalServerError     # -32099..-32000
       ├── Errors::UnknownError            # any other code
       └── Errors::MalformedResponseError  # bad framing/JSON, id mismatch, wrong jsonrpc version
```

`MalformedResponseError` is a `ServerError`, not a `ClientError`: a malformed response is the peer's fault.

```ruby
begin
  client.request(:do_thing, [1, 2])
rescue JRPC::Errors::ServerError => e
  warn "rpc error #{e.code}: #{e.message}"
rescue JRPC::Errors::Timeout
  warn "timed out"
rescue JRPC::Errors::ConnectionError => e
  warn "connection: #{e.message} (cause: #{e.cause})"
end
```

## JSON serialization

JRPC uses the stdlib `json`. To swap in [oj](https://github.com/ohler55/oj) for speed, monkey-patch it yourself before use:

```ruby
require 'oj'
Oj.mimic_JSON
```

## TCP MD5 Signature (RFC2385)

Both clients accept `tcp_md5_pass:` to enable per-connection authentication via the
[TCP MD5 Signature option](https://www.rfc-editor.org/rfc/rfc2385). The kernel signs and
verifies every TCP segment with `MD5(key + segment + addresses/ports)`; a peer with a
mismatched or absent key has its segments silently dropped, so the handshake never
completes.

```ruby
client = JRPC::SimpleClient.new("10.0.0.2:1234", tcp_md5_pass: "shared-secret")
```

- **Linux-only.** It relies on the `TCP_MD5SIG` socket option (and a kernel built with
  `CONFIG_TCP_MD5SIG`). When `tcp_md5_pass` is set on a platform/kernel without it, the
  first connect raises `ConnectionError` — the option never silently no-ops.
- **The server must be configured with the same key for this client's address.** JRPC
  only sets the client side; the peer (e.g. a router/BGP-style endpoint, or another
  socket with a matching `TCP_MD5SIG`) must agree on the key.
- **Key length is capped at 80 bytes** (`TCP_MD5SIG_MAXKEYLEN`); a longer key raises
  `ConnectionError`.
- The key is installed on the socket **before** connect, so it also protects the
  handshake itself. It survives reconnects (reaping, connection drops) transparently.

## CLI tools

Two executables ship with the gem:

- `jrpc` — one-shot request/notification from the shell (`jrpc --help`).
- `jrpc-shell` — an interactive REPL (`connect`, `request`, `notification`, `disconnect`).

Both use `SimpleClient`.

## Upgrading from 1.x

2.0 is a full rewrite with many breaking changes (`JRPC::TcpClient`/`BaseClient` removed, error constants moved under `JRPC::Errors::*`, `method_missing`/`namespace:` dropped, no eager connect, and more). See the [CHANGELOG](CHANGELOG.md) for the complete list.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/didww/jrpc.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
