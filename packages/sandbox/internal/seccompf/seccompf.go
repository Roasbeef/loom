// Package seccompf builds and installs the network-off seccomp filter.
//
// Under network mode "off" the policy's intent is: no sockets to the
// outside world. The enforcement point is socket *creation*: seccomp
// cannot dereference the sockaddr pointer passed to connect(2), but it
// can read the integer domain argument of socket(2)/socketpair(2). If a
// process can never obtain an AF_INET/AF_INET6/AF_PACKET/... socket, it
// has nothing to connect(), bind(), or sendto() with — the helper
// constructs the child's fd table and environment, so no network fd can
// be smuggled in. AF_UNIX is allowed: it reaches only the filesystem
// view, which bwrap/Landlock already confine.
//
// The program is constructed as pure data (testable without a kernel)
// and installed with SECCOMP_FILTER_FLAG_TSYNC so it binds every thread
// of the multithreaded Go runtime, not just the calling one — without
// TSYNC another runtime thread could simply make the blocked syscall.
// Installation requires no_new_privs, which also guarantees the filter
// cannot be used to confuse a setuid binary. Both no_new_privs and the
// filter persist across execve, which is the whole trick: the helper
// restricts itself, then execs the untrusted target into the cage.
//
// The package is split by platform, and this file holds only the
// documentation. `seccompf_linux.go` has the real filter — its
// construction and its installation. `seccompf_other.go` has the stub
// that reports the layer unavailable everywhere else, so the helper still
// *compiles* off Linux and says out loud that it has no network filter,
// rather than failing to build with a message about kernel constants.
package seccompf
