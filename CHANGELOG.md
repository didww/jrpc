# Changelog

### Unreleased

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
