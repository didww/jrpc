# Changelog

### Unreleased

**New**

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
