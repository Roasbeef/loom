//go:build linux

package main

import (
	"fmt"
	"io"
	"os"
	"strconv"

	"golang.org/x/sys/unix"
)

// tcpULP is TCP_ULP, spelled as its ABI value because x/sys does not
// export it on every architecture this builds for.
const tcpULP = 31

// probeLoopback is the in-jail witness for network mode loopback. It
// uses raw system calls rather than package net on purpose: net probes
// for IPv6 and silently falls back, and a witness has to report the
// errno the filter or the namespace produced, not the one net chose to
// show. Roles, by first argument:
//
//	battery [PORT]  print one `name=result` line per check: a TCP
//	                connection to a listener of its own, the sockets
//	                the mode must refuse, TCP_ULP, a connection to a
//	                non-loopback address, and, when PORT is given, a
//	                connection to 127.0.0.1:PORT;
//	hold            listen on 127.0.0.1, print `port=N`, and accept
//	                connections until stdin reaches EOF;
//	dial PORT       connect to 127.0.0.1:PORT and print the result.
func probeLoopback(args []string) {
	if len(args) == 0 {
		fmt.Println("usage: --probe-loopback battery [PORT] | hold | dial PORT")
		os.Exit(2)
	}
	switch args[0] {
	case "battery":
		port := ""
		if len(args) > 1 {
			port = args[1]
		}
		loopbackBattery(port)
	case "hold":
		loopbackHold()
	case "dial":
		if len(args) < 2 {
			fmt.Println("dial=needs-port")
			os.Exit(2)
		}
		fmt.Printf("dial=%s\n", loopbackDial(args[1]))
	default:
		fmt.Printf("unknown role %q\n", args[0])
		os.Exit(2)
	}
}

// errName renders an error as its errno name where it has one.
func errName(err error) string {
	if err == nil {
		return "ok"
	}
	if errno, ok := err.(unix.Errno); ok {
		if name := unix.ErrnoName(errno); name != "" {
			return name
		}
	}
	return err.Error()
}

// listenLoopback returns a listening socket on 127.0.0.1 and its port.
func listenLoopback() (int, int, error) {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, 0, err
	}
	if err := unix.Bind(fd, &unix.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}); err != nil {
		unix.Close(fd)
		return -1, 0, err
	}
	if err := unix.Listen(fd, 8); err != nil {
		unix.Close(fd)
		return -1, 0, err
	}
	sa, err := unix.Getsockname(fd)
	if err != nil {
		unix.Close(fd)
		return -1, 0, err
	}
	return fd, sa.(*unix.SockaddrInet4).Port, nil
}

// connectTo makes one TCP connection attempt and closes the socket.
func connectTo(addr [4]byte, port int) error {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	return unix.Connect(fd, &unix.SockaddrInet4{Addr: addr, Port: port})
}

func loopbackDial(portText string) string {
	port, err := strconv.Atoi(portText)
	if err != nil {
		return "bad-port"
	}
	return errName(connectTo([4]byte{127, 0, 0, 1}, port))
}

func loopbackHold() {
	fd, port, err := listenLoopback()
	if err != nil {
		fmt.Printf("hold=%s\n", errName(err))
		os.Exit(1)
	}
	fmt.Printf("port=%d\n", port)

	// Accept in the background so the stdin read below can end the
	// probe. Closing stdin is how the test releases the holder.
	go func() {
		for {
			conn, _, err := unix.Accept(fd)
			if err != nil {
				return
			}
			unix.Close(conn)
		}
	}()
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func loopbackBattery(hostPort string) {
	// A TCP connection to a listener this process owns.
	fd, port, err := listenLoopback()
	if err != nil {
		fmt.Printf("listen=%s\n", errName(err))
	} else {
		fmt.Printf("listen=ok\nself-connect=%s\n",
			errName(connectTo([4]byte{127, 0, 0, 1}, port)))
		unix.Close(fd)
	}

	// Non-loopback destinations have no route in the namespace.
	fmt.Printf("connect-doc-range=%s\n", errName(connectTo([4]byte{192, 0, 2, 1}, 80)))
	fmt.Printf("connect-private=%s\n", errName(connectTo([4]byte{10, 0, 0, 1}, 80)))
	if hostPort != "" {
		fmt.Printf("connect-host-port=%s\n", loopbackDial(hostPort))
	}

	// Sockets the mode must refuse with EPERM.
	refused := []struct {
		name                string
		domain, typ, protoc int
	}{
		{"socket-inet6-stream", unix.AF_INET6, unix.SOCK_STREAM, 0},
		{"socket-inet-dgram", unix.AF_INET, unix.SOCK_DGRAM, 0},
		{"socket-inet-raw", unix.AF_INET, unix.SOCK_RAW, unix.IPPROTO_ICMP},
		{"socket-inet-sctp", unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_SCTP},
		{"socket-inet-mptcp", unix.AF_INET, unix.SOCK_STREAM, unix.IPPROTO_MPTCP},
		{"socket-packet", unix.AF_PACKET, unix.SOCK_RAW, 0},
		{"socket-netlink-route", unix.AF_NETLINK, unix.SOCK_RAW, unix.NETLINK_ROUTE},
		{"socket-netlink-generic", unix.AF_NETLINK, unix.SOCK_RAW, unix.NETLINK_GENERIC},
	}
	for _, r := range refused {
		s, err := unix.Socket(r.domain, r.typ, r.protoc)
		if err == nil {
			unix.Close(s)
		}
		fmt.Printf("%s=%s\n", r.name, errName(err))
	}
	if pair, err := unix.Socketpair(unix.AF_INET, unix.SOCK_STREAM, 0); err == nil {
		unix.Close(pair[0])
		unix.Close(pair[1])
		fmt.Println("socketpair-inet=ok")
	} else {
		fmt.Printf("socketpair-inet=%s\n", errName(err))
	}
	if pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0); err == nil {
		unix.Close(pair[0])
		unix.Close(pair[1])
		fmt.Println("socketpair-unix=ok")
	} else {
		fmt.Printf("socketpair-unix=%s\n", errName(err))
	}

	// TCP_ULP on an otherwise permitted TCP socket, and a harmless
	// option on the same socket to show only TCP_ULP is refused.
	if s, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM, 0); err == nil {
		fmt.Printf("setsockopt-tcp-nodelay=%s\n",
			errName(unix.SetsockoptInt(s, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)))
		fmt.Printf("setsockopt-tcp-ulp=%s\n",
			errName(unix.SetsockoptString(s, unix.IPPROTO_TCP, tcpULP, "tls")))
		unix.Close(s)
	} else {
		fmt.Printf("setsockopt-tcp-ulp=no-socket:%s\n", errName(err))
	}
}
