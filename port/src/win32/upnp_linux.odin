package win32

import "core:net"
import "core:sys/linux"

// The address this machine sends to the internet from: a UDP socket
// connected to a public address (no packet goes out) is bound to it.
upnp_route_address :: proc() -> (net.IP4_Address, bool) {
	fd, errno := linux.socket(.INET, .DGRAM, {}, .HOPOPT)
	if errno != .NONE {return {}, false}
	defer linux.close(fd)
	to := linux.Sock_Addr_In{sin_family = .INET, sin_port = 53, sin_addr = UPNP_ROUTE_PROBE}
	if linux.connect(fd, &to) != .NONE {return {}, false}
	at: linux.Sock_Addr_Any
	if linux.getsockname(fd, &at) != .NONE || at.family != .INET {return {}, false}
	return net.IP4_Address(at.sin_addr), true
}
