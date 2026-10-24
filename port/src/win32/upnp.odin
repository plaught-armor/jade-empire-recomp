// The router's port forward for an open host (net.odin): a thread finds the
// internet gateway by SSDP, reads its description for the WAN connection's
// control URL and asks it by SOAP to forward the host's UDP port and for
// the public address. The main thread (pump) puts the address the joiner
// needs in the window title and on the clipboard; at exit the forward goes.
// A router without UPnP leaves the title saying which port to forward.
// WHY: docs/hle.md §11
package win32

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

UPNP_SSDP :: net.Endpoint{net.IP4_Address{239, 255, 255, 250}, 1900}
UPNP_SEARCH :: "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
UPNP_SEARCH_TIME :: 3 * time.Second
UPNP_HTTP_TIME :: 3 * time.Second
// The WAN services that forward ports, in the order tried.
UPNP_SERVICES :: [?]string {
	"urn:schemas-upnp-org:service:WANIPConnection:2",
	"urn:schemas-upnp-org:service:WANIPConnection:1",
	"urn:schemas-upnp-org:service:WANPPPConnection:1",
}
UPNP_HTTP_MAX :: 64 * 1024
// Where upnp_route_address aims: any public address will do.
UPNP_ROUTE_PROBE :: [4]u8{8, 8, 8, 8}

Upnp :: struct {
	port:     int,
	thread:   ^thread.Thread,
	done:     bool, // atomic: the thread has finished and the fields below hold
	shown:    bool, // upnp_poll has put the outcome in the title
	mapped:   bool,
	router:   net.Endpoint, // the gateway's control endpoint
	control:  string, // its control URL's path
	service:  string,
	local:    string, // this machine's LAN address
	external: string, // the public address, "" when the router did not say
	why:      string, // why there is no forward
	via:      net.IP4_Address, // the address this machine reached the router from
}

@(private = "file")
up: Upnp

// Starts asking the router to forward UDP port p to this machine.
upnp_start :: proc(p: int) {
	up = {port = p}
	title_set(fmt.tprintf("hosting online on port %d, opening the router...", p))
	up.thread = thread.create_and_start(upnp_run)
}

// The thread's outcome into the title and onto the clipboard, once.
upnp_poll :: proc() {
	if up.thread == nil || up.shown || !sync.atomic_load(&up.done) {return}
	up.shown = true
	if up.mapped && up.external != "" {
		addr := fmt.tprintf("%s:%d", up.external, up.port)
		title_set(fmt.tprintf("hosting online at %s (copied to clipboard)", addr))
		_ = sdl.SetClipboardText(fmt.ctprintf("%s", addr))
		fmt.eprintfln("upnp: forwarded UDP %d, join at %s", up.port, addr)
		return
	}
	lan := up.local != "" ? fmt.tprintf("%s:%d", up.local, up.port) : fmt.tprintf("port %d", up.port)
	title_set(fmt.tprintf("hosting on port %d; LAN %s; router did not open the port (forward UDP %d by hand)", up.port, lan, up.port))
	if up.local != "" {_ = sdl.SetClipboardText(fmt.ctprintf("%s", lan))}
	fmt.eprintfln("upnp: no forward (%s); LAN address %s", up.why, lan)
}

// Takes the forward back; a thread still asking is left be.
upnp_close :: proc() {
	if up.thread == nil || !sync.atomic_load(&up.done) || !up.mapped {return}
	up.mapped = false
	args := fmt.tprintf("<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol>", up.port)
	_, ok := upnp_soap("DeletePortMapping", args)
	fmt.eprintfln("upnp: %s the forward of UDP %d", ok ? "removed" : "could not remove", up.port)
}

@(private = "file")
upnp_run :: proc() {
	defer sync.atomic_store(&up.done, true)
	up.local = upnp_lan_address()
	location, found := upnp_search()
	if !found {
		up.why = "no router answered"
		return
	}
	if !upnp_describe(location) {return}
	if up.via != {} {up.local = fmt.aprintf("%d.%d.%d.%d", up.via[0], up.via[1], up.via[2], up.via[3])}
	args := fmt.tprintf(
		"<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol>" +
		"<NewInternalPort>%d</NewInternalPort><NewInternalClient>%s</NewInternalClient><NewEnabled>1</NewEnabled>" +
		"<NewPortMappingDescription>Jade Empire</NewPortMappingDescription><NewLeaseDuration>%d</NewLeaseDuration>",
		up.port, up.port, up.local, 0,
	)
	_, ok := upnp_soap("AddPortMapping", args)
	if !ok {
		// Some routers take only forwards that lapse.
		_, ok = upnp_soap("AddPortMapping", strings.concatenate({args[:strings.last_index(args, "<NewLeaseDuration>")], "<NewLeaseDuration>7200</NewLeaseDuration>"}, context.temp_allocator))
	}
	if !ok {
		up.why = "the router refused the forward"
		return
	}
	up.mapped = true
	if body, got := upnp_soap("GetExternalIPAddress", ""); got {
		up.external = strings.clone(upnp_tag(body, "NewExternalIPAddress"))
	}
	if up.external == "" {up.why = "the router gave no public address"}
}

// The first gateway's description URL.
@(private = "file")
upnp_search :: proc() -> (location: string, ok: bool) {
	sock, err := net.make_unbound_udp_socket(.IP4)
	if err != nil {return}
	defer net.close(sock)
	if net.set_option(sock, .Receive_Timeout, 500 * time.Millisecond) != nil {return}
	start := time.tick_now()
	for tries := 0; time.tick_since(start) < UPNP_SEARCH_TIME; tries += 1 {
		if tries % 2 == 0 {_, _ = net.send_udp(sock, transmute([]u8)string(UPNP_SEARCH), UPNP_SSDP)}
		buf: [2048]u8
		n, _, rerr := net.recv_udp(sock, buf[:])
		if rerr != nil || n <= 0 {continue}
		if l := upnp_header(string(buf[:n]), "location"); l != "" {return strings.clone(l), true}
	}
	return
}

// A header's value from an HTTP head, its name in lower case.
@(private = "file")
upnp_header :: proc(head, name: string) -> string {
	rest := head
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {continue}
		if strings.equal_fold(strings.trim_space(line[:colon]), name) {return strings.trim_space(line[colon + 1:])}
	}
	return ""
}

// An http:// URL's endpoint and path.
@(private = "file")
upnp_url :: proc(url: string) -> (ep: net.Endpoint, path: string, ok: bool) {
	rest := strings.trim_prefix(url, "http://")
	if len(rest) == len(url) {return}
	slash := strings.index_byte(rest, '/')
	host := slash < 0 ? rest : rest[:slash]
	path = slash < 0 ? "/" : rest[slash:]
	ep = net.parse_endpoint(host) or_return
	if ep.port == 0 {ep.port = 80}
	return ep, path, true
}

// Reads the gateway's description at location for a WAN service and its
// control URL.
@(private = "file")
upnp_describe :: proc(location: string) -> bool {
	ep, path, ok := upnp_url(location)
	if !ok {
		up.why = fmt.aprintf("the router's address %s is not http", location)
		return false
	}
	req := fmt.tprintf("GET %s HTTP/1.0\r\nHost: %v\r\nConnection: close\r\n\r\n", path, ep)
	body, got := upnp_http(ep, req)
	if !got {
		up.why = "the router's description did not load"
		return false
	}
	for s in UPNP_SERVICES {
		at := strings.index(body, fmt.tprintf("<serviceType>%s</serviceType>", s))
		if at < 0 {continue}
		ctl := upnp_tag(body[at:], "controlURL")
		if ctl == "" {continue}
		if strings.has_prefix(ctl, "http://") {
			cep, cpath, cok := upnp_url(ctl)
			if !cok {continue}
			up.router, up.control = cep, strings.clone(cpath)
		} else {
			up.router, up.control = ep, strings.concatenate({strings.has_prefix(ctl, "/") ? "" : "/", ctl})
		}
		up.service = s
		return true
	}
	up.why = "the router has no port forwarding service"
	return false
}

// What lies between <name> and </name> in s.
@(private = "file")
upnp_tag :: proc(s, name: string) -> string {
	open := fmt.tprintf("<%s>", name)
	at := strings.index(s, open)
	if at < 0 {return ""}
	rest := s[at + len(open):]
	end := strings.index(rest, fmt.tprintf("</%s>", name))
	return end < 0 ? "" : strings.trim_space(rest[:end])
}

// Calls action on the WAN service with args: the reply's body and whether
// it said 200.
@(private = "file")
upnp_soap :: proc(action, args: string) -> (body: string, ok: bool) {
	env := fmt.tprintf(
		"<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
		"s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:%s xmlns:u=\"%s\">%s</u:%s></s:Body></s:Envelope>",
		action, up.service, args, action,
	)
	req := fmt.tprintf(
		"POST %s HTTP/1.0\r\nHost: %v\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nSOAPAction: \"%s#%s\"\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		up.control, up.router, up.service, action, len(env), env,
	)
	return upnp_http(up.router, req)
}

// Sends req to ep over TCP and reads the reply to its end: the body and
// whether the status was 200.
@(private = "file")
upnp_http :: proc(ep: net.Endpoint, req: string) -> (body: string, ok: bool) {
	sock, err := net.dial_tcp_from_endpoint(ep)
	if err != nil {return}
	defer net.close(sock)
	if b, berr := net.bound_endpoint(sock); berr == nil {
		if a, is4 := b.address.(net.IP4_Address); is4 {up.via = a}
	}
	if net.set_option(sock, .Receive_Timeout, UPNP_HTTP_TIME) != nil {return}
	if net.set_option(sock, .Send_Timeout, UPNP_HTTP_TIME) != nil {return}
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {return}
	buf := make([]u8, UPNP_HTTP_MAX, context.temp_allocator)
	n := 0
	for n < len(buf) {
		got, rerr := net.recv_tcp(sock, buf[n:])
		if rerr != nil || got <= 0 {break}
		n += got
	}
	reply := string(buf[:n])
	end := strings.index(reply, "\r\n\r\n")
	if end < 0 {return}
	status := reply[:max(strings.index(reply, "\r\n"), 0)]
	fields := strings.fields(status, context.temp_allocator)
	code := len(fields) >= 2 ? (strconv.parse_int(fields[1]) or_else 0) : 0
	return reply[end + 4:], code == 200
}

// This machine's LAN address until the router is reached: the one it
// reaches the internet from, or "".
@(private = "file")
upnp_lan_address :: proc() -> string {
	a, ok := upnp_route_address()
	if !ok || a == {} {return ""}
	return fmt.aprintf("%d.%d.%d.%d", a[0], a[1], a[2], a[3])
}
