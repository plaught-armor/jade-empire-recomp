package win32

import "core:net"
import win "core:sys/windows"

// The address this machine sends to the internet from: a UDP socket
// connected to a public address (no packet goes out) is bound to it.
upnp_route_address :: proc() -> (net.IP4_Address, bool) {
	s := win.socket(win.AF_INET, win.SOCK_DGRAM, 0)
	if s == win.INVALID_SOCKET {return {}, false}
	defer win.closesocket(s)
	to: win.SOCKADDR_STORAGE_LH
	(^win.sockaddr_in)(&to)^ = {sin_family = u16(win.AF_INET), sin_port = 53, sin_addr = transmute(win.in_addr)UPNP_ROUTE_PROBE}
	if win.connect(s, &to, size_of(win.sockaddr_in)) != 0 {return {}, false}
	at: win.SOCKADDR_STORAGE_LH
	n := i32(size_of(at))
	if win.getsockname(s, &at, &n) != 0 || at.ss_family != u16(win.AF_INET) {return {}, false}
	return net.IP4_Address(transmute([4]u8)(^win.sockaddr_in)(&at).sin_addr), true
}
