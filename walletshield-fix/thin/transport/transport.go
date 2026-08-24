// SPDX-FileCopyrightText: (c) 2024, 2025  David Stainton.
// SPDX-License-Identifier: AGPL-3.0-only

package transport

// DialConfig contains the configuration for connecting to a thin client daemon.
type DialConfig struct {
	Unix *UnixDialConfig `cbor:"unix,omitempty"`
	Tcp  *TcpDialConfig  `cbor:"tcp,omitempty"`
}

// UnixDialConfig is the configuration for connecting via Unix domain socket.
type UnixDialConfig struct {
	Address string `cbor:"address"`
}

// TcpDialConfig is the configuration for connecting via TCP.
type TcpDialConfig struct {
	Address string `cbor:"address"`
	Network string `cbor:"network"`
}

// ListenConfig contains the configuration for listening for thin client connections.
type ListenConfig struct {
	Unix *UnixListenConfig `cbor:"unix,omitempty"`
	Tcp  *TcpListenConfig  `cbor:"tcp,omitempty"`
}

// UnixListenConfig is the configuration for listening on a Unix domain socket.
type UnixListenConfig struct {
	Address string `cbor:"address"`
}

// TcpListenConfig is the configuration for listening on TCP.
type TcpListenConfig struct {
	Address string `cbor:"address"`
	Network string `cbor:"network"`
}
