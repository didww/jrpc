# Changelog

### 2.2.0

**New**

* `JRPC::Errors::ServerError#data` — the JSON-RPC `error.data` member is now carried
  onto the raised exception instead of being dropped. `Message.error_to_exception`
  reads `error['data']` and passes it to every `ServerError` subclass built from a peer
  error object, verbatim and untyped (String, Hash, Array, … — whatever the peer sent),
  `nil` when omitted. It is the only machine-readable detail an error object carries
  beyond `code`, and servers use it to say *which* param was invalid or *which* id
  conflicted. `MalformedResponseError` is raised locally rather than mapped from a peer
  error object, so its `data` is always `nil`.
  `JRPC::Transport::Test` emits a `data` member when a handler raises an error that
  carries one, so the round trip is testable. Backwards compatible: on those classes
  `data:` is a keyword with a `nil` default, and the wire frame is unchanged when there
  is no data — the member is omitted, never emitted as `null`.

### 2.1.0

**New**

* Debug-level wire-payload logging. When a `logger:` is configured, both
  `SimpleClient` and `SharedClient` emit every request/response payload (the raw
  JSON frame, exactly as written/read) at `DEBUG`, tagged `[JRPC::SimpleClient]`
  / `[JRPC::SharedClient]` with `>>` (sent) / `<<` (received) markers. No logger,
  no logging.
* `JRPC::Transport::Test` — an in-process transport double for testing code that
  uses JRPC, without a real server. Not required by default: `require
  'jrpc/transport/test'`, then inject via `transport:` on either client. Stub
  methods with `on('method') { |params| ... }` (return value becomes the result;
  raise a `JRPC::Errors::ServerError` for an error response, or a transport error
  to simulate a socket failure); records `requests`/`notifications`/`sent` for
  assertions. A raw escape hatch (`push_response`/`push_raise`, `strict: false`)
  covers malformed-response, id-mismatch, and orphan-frame cases. Works with both
  `SimpleClient` and `SharedClient`. (Closes #10.)
* Optional TCP MD5 Signature (RFC2385) support. Pass `tcp_md5_pass:` to
  `SimpleClient`/`SharedClient` (or the transport directly) to authenticate the
  connection with a per-peer MD5 key. Linux-only (`TCP_MD5SIG`); the key is
  installed on the socket before connect, and a connect on a kernel/platform
  without `TCP_MD5SIG` raises `ConnectionError`.

### 2.0.0

Full rewrite. JRPC 2.0 is not API-compatible with 1.x.

**New**

* `JRPC::SharedClient` — one shared instance, one connection, serving many caller
  threads and/or fibers. Owns a dedicated transport thread that multiplexes
  responses by id. Supports Puma threads, rage-rb/Falcon fibers, and mixed
  thread/fiber callers. Fiber callers require a spec-compliant `Fiber.scheduler`.
  (Internally drafted as `ThreadQueueClient`; never shipped under that name.)
* `JRPC::SimpleClient` — single-threaded client, the functional replacement for
  the old `TcpClient`.
* `concurrent-ruby` (`~> 1.2`) added as a runtime dependency (backs the shared
  client's result futures).
* `logger` added as an explicit runtime dependency (no longer guaranteed bundled
  on Ruby 3.5+).

**Removed / breaking**

* `JRPC::TcpClient` removed — use `JRPC::SimpleClient`.
* `JRPC::BaseClient` removed, including the `BaseClient.connect` block helper.
* All top-level error constants moved under `JRPC::Errors::*`.
* `method_missing` magic removed — pass the full method name as a String or Symbol.
* `invoke_request` / `invoke_notification` removed.
* `perform_request` removed — use `request` and `notification`.
* `namespace:` option removed.
* Umbrella `timeout:` option removed — use `read_timeout` / `write_timeout` /
  `connect_timeout` (`SimpleClient`), or `ttl:` (`SharedClient`).
* `close_after_sent:` renamed to `autoclose:`.
* `connect_retry_count` default changed from `10` to `0`.
* Constructors no longer connect eagerly — the first call connects.
* Malformed responses now raise `Errors::MalformedResponseError` (a `ServerError`),
  not `ClientError`. In 1.x the missing-comma-terminator case raised `ClientError`.
* `SimpleClient` read/write/connect timeouts now raise `Errors::Timeout`, not
  `ConnectionError`.
* `oj` runtime dependency dropped — JRPC uses stdlib `json`. For Oj speed,
  `require 'oj'; Oj.mimic_JSON` yourself.
* `netstring` is no longer a dependency — framing is owned in-tree by the transport.
* `required_ruby_version` set to `>= 3.3` (the floor where the
  `ConditionVariable` ↔ `Fiber.scheduler` cooperation that fiber callers depend on
  is verified).
* `bin/jrpc` and `bin/jrpc-shell` rewritten on top of `SimpleClient`; flag/usage
  changes (see `README.md` and `jrpc --help`).

### 1.1.8
* handling FIN signal for TCP socket [didww/jrpc#19](https://github.com/didww/jrpc/pull/19)
* add gem executables [didww/jrpc#19](https://github.com/didww/jrpc/pull/19)

### 1.1.7
* connect ot socket in nonblock mode

### 1.1.6
* update oj version to ~> 3.0

### 1.1.5
* update oj version to ~> 2.0

### 1.1.4
* handle EOF on read
* fix jrpc error require
* use JRPC::Error as base class for JRPC::Transport::SocketBase::Error

### 1.1.3
* close socket when clearing socket if it's not closed

### 1.1.2
* reset socket when broken pipe error appears

### 1.1.1
* fix rescuing error in TcpClient initializer

### 1.1.0
* use own socket wrapper

### 1.0.1
* Net::TCPClient#read method process data with buffer variable

### 1.0.0
* stable release
