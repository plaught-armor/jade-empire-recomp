// The part of the C runtime that Visual Studio's static libraries (libcmt,
// libvcruntime) would put in a Windows exe, so the exe links with Odin's
// lld-link alone: the startup that calls Odin's main, the thread-local
// storage directory, __chkstk, _fltused, memcpy and memmove. Everything
// else comes from ucrtbase.dll, part of every Windows 10 and later.
// Built into lib/jadecrt.lib by build.sh: /Zl (no default libraries), /GS-
// (no security cookie, which needs libcmt's).
// WHY: docs/hle.md §13

typedef unsigned long long size_t;
typedef unsigned long ulong;
typedef unsigned char u8;

// Odin's entry point when it links against a C runtime.
int main(int argc, char **argv);

// ucrtbase.dll: what libcmt's mainCRTStartup does before main, for a
// console program with narrow (UTF-8 under Odin's code page) arguments.
enum { _crt_argv_unexpanded_arguments = 1 };
int _configure_narrow_argv(int mode);
int _initialize_narrow_environment(void);
int *__p___argc(void);
char ***__p___argv(void);
int _set_app_type(int type);
int _initialize_onexit_table(void *table);
void exit(int code);

int mainCRTStartup(void) {
	_set_app_type(1); // _crt_console_app
	_configure_narrow_argv(_crt_argv_unexpanded_arguments);
	_initialize_narrow_environment();
	exit(main(*__p___argc(), *__p___argv()));
	return 0;
}

// Thread-local storage: the loader reads _tls_used (the PE TLS directory)
// and copies .tls, from _tls_start to _tls_end, into each thread's block.
// LLVM puts thread-local variables in .tls$, between the two.
typedef void (*tls_callback)(void *, ulong, void *);
typedef struct {
	size_t start, end, index, callbacks;
	ulong zero_fill, characteristics;
} tls_directory;

ulong _tls_index = 0;
#pragma section(".tls", read, write)
#pragma section(".tls$ZZZ", read, write)
#pragma section(".CRT$XLA", read)
#pragma section(".CRT$XLZ", read)
#pragma section(".rdata$T", read)
__declspec(allocate(".tls")) char _tls_start = 0;
__declspec(allocate(".tls$ZZZ")) char _tls_end = 0;
// No TLS callbacks: the list from __xl_a + 1 is empty, ended by __xl_z.
__declspec(allocate(".CRT$XLA")) const tls_callback __xl_a = 0;
__declspec(allocate(".CRT$XLZ")) const tls_callback __xl_z = 0;
__declspec(allocate(".rdata$T")) const tls_directory _tls_used = {
	(size_t)&_tls_start, (size_t)&_tls_end, (size_t)&_tls_index, (size_t)(&__xl_a + 1), 0, 0,
};

// Tells MSVC-style objects that floating point is in use; nothing reads it.
int _fltused = 0;

// Probes each page of a stack allocation of rax bytes, so the guard page
// grows the stack in order (compiler-rt's chkstk.S).
__attribute__((naked)) void __chkstk(void) {
	__asm__ volatile(
		"push %rcx\n"
		"push %rax\n"
		"cmp $0x1000, %rax\n"
		"lea 24(%rsp), %rcx\n"
		"jb 1f\n"
		"2:\n"
		"sub $0x1000, %rcx\n"
		"test %rcx, (%rcx)\n"
		"sub $0x1000, %rax\n"
		"cmp $0x1000, %rax\n"
		"ja 2b\n"
		"1:\n"
		"sub %rax, %rcx\n"
		"test %rcx, (%rcx)\n"
		"pop %rax\n"
		"pop %rcx\n"
		"ret\n");
}

// memcpy and memmove live in vcruntime140.dll, which Windows does not ship,
// so they are here: rep movsb, fast on every CPU with ERMS (x86-64-v3 ones).
void *memcpy(void *dst, const void *src, size_t n) {
	void *d = dst;
	__asm__ volatile("rep movsb" : "+D"(d), "+S"(src), "+c"(n) : : "memory");
	return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
	u8 *d = dst;
	const u8 *s = src;
	if (d <= s || d >= s + n) {return memcpy(dst, src, n);}
	// Overlapping with dst above src: copy backwards.
	d += n - 1;
	s += n - 1;
	__asm__ volatile("std\n rep movsb\n cld" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
	return dst;
}
