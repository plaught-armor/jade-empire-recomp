// d3dx9_29 math: D3D matrices are row-major with row vectors (v' = v * M),
// so M[r][c] is the f32 at byte (r*4 + c)*4. Floats arrive as raw bits in
// stdcall argument slots.
package win32

import "base:intrinsics"
import "core:math"
import "../x86"

D3DX := [?]Hle_Entry {
	{"d3dx9_29.dll!D3DXCreateMatrixStack", D3DXCreateMatrixStack},
	{"d3dx9_29.dll!D3DXVec3Normalize", D3DXVec3Normalize},
	{"d3dx9_29.dll!D3DXMatrixMultiply", D3DXMatrixMultiply},
	{"d3dx9_29.dll!D3DXMatrixTranspose", D3DXMatrixTranspose},
	{"d3dx9_29.dll!D3DXMatrixInverse", D3DXMatrixInverse},
	{"d3dx9_29.dll!D3DXMatrixScaling", D3DXMatrixScaling},
	{"d3dx9_29.dll!D3DXMatrixOrthoOffCenterRH", D3DXMatrixOrthoOffCenterRH},
	{"d3dx9_29.dll!D3DXMatrixPerspectiveFovRH", D3DXMatrixPerspectiveFovRH},
	{"d3dx9_29.dll!D3DXFilterTexture", D3DXFilterTexture},
	{"d3dx9_29.dll!D3DXCreateTexture", D3DXCreateTexture},
	{"d3dx9_29.dll!D3DXCreateCubeTexture", D3DXCreateCubeTexture},
	{"d3dx9_29.dll!D3DXLoadSurfaceFromSurface", D3DXLoadSurfaceFromSurface},
}

Mat :: [4][4]f32

MAT_IDENTITY :: Mat{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}}

argf :: #force_inline proc "contextless" (i: u32) -> f32 {
	return transmute(f32)arg(i)
}

rdf :: #force_inline proc "contextless" (a: u32) -> f32 {
	return transmute(f32)ld32(a)
}

// Matrices move as one block; a JE_WATCH build stores word by word so the
// write watch sees each store.
rd_mat :: #force_inline proc "contextless" (p: u32) -> Mat {
	return intrinsics.unaligned_load((^Mat)(&x86.mem[p]))
}

wr_mat :: proc "contextless" (p: u32, m: Mat) {
	when x86.WATCH {
		m := transmute([16]u32)m
		for i in 0 ..< u32(16) {x86.wr32(p + i * 4, m[i])}
	} else {
		intrinsics.unaligned_store((^Mat)(&x86.mem[p]), m)
	}
}

// One row at a time in four lanes; each lane sums in the scalar order
// a[i][0]*b[0][j] + a[i][1]*b[1][j] + a[i][2]*b[2][j] + a[i][3]*b[3][j], so the
// result is bit-identical to the scalar loop.
mat_mul :: proc "contextless" (a, b: Mat) -> Mat {
	Row :: #simd[4]f32
	rb := transmute([4]Row)b
	m: [4]Row
	#no_bounds_check for i in 0 ..< 4 {
		r := a[i]
		m[i] = Row(r[0]) * rb[0] + Row(r[1]) * rb[1] + Row(r[2]) * rb[2] + Row(r[3]) * rb[3]
	}
	return transmute(Mat)m
}

mat_transpose :: proc "contextless" (a: Mat) -> (m: Mat) {
	#no_bounds_check for i in 0 ..< 4 {
		for j in 0 ..< 4 {
			m[i][j] = a[j][i]
		}
	}
	return
}

// General 4x4 inverse by cofactors; ok false when singular.
mat_inverse :: proc(a: Mat) -> (inv: Mat, det: f32, ok: bool) {
	m := transmute([16]f32)a
	t: [16]f32
	t[0] = m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10]
	t[4] = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10]
	t[8] = m[4]*m[9]*m[15] - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9]
	t[12] = -m[4]*m[9]*m[14] + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9]
	t[1] = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10]
	t[5] = m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10]
	t[9] = -m[0]*m[9]*m[15] + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9]
	t[13] = m[0]*m[9]*m[14] - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9]
	t[2] = m[1]*m[6]*m[15] - m[1]*m[7]*m[14] - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7] - m[13]*m[3]*m[6]
	t[6] = -m[0]*m[6]*m[15] + m[0]*m[7]*m[14] + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7] + m[12]*m[3]*m[6]
	t[10] = m[0]*m[5]*m[15] - m[0]*m[7]*m[13] - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7] - m[12]*m[3]*m[5]
	t[14] = -m[0]*m[5]*m[14] + m[0]*m[6]*m[13] + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6] + m[12]*m[2]*m[5]
	t[3] = -m[1]*m[6]*m[11] + m[1]*m[7]*m[10] + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7] + m[9]*m[3]*m[6]
	t[7] = m[0]*m[6]*m[11] - m[0]*m[7]*m[10] - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7] - m[8]*m[3]*m[6]
	t[11] = -m[0]*m[5]*m[11] + m[0]*m[7]*m[9] + m[4]*m[1]*m[11] - m[4]*m[3]*m[9] - m[8]*m[1]*m[7] + m[8]*m[3]*m[5]
	t[15] = m[0]*m[5]*m[10] - m[0]*m[6]*m[9] - m[4]*m[1]*m[10] + m[4]*m[2]*m[9] + m[8]*m[1]*m[6] - m[8]*m[2]*m[5]
	det = m[0] * t[0] + m[1] * t[4] + m[2] * t[8] + m[3] * t[12]
	if det == 0 {
		return {}, 0, false
	}
	for &v in t {
		v /= det
	}
	return transmute(Mat)t, det, true
}

mat_scaling :: proc(x, y, z: f32) -> Mat {
	return Mat{{x, 0, 0, 0}, {0, y, 0, 0}, {0, 0, z, 0}, {0, 0, 0, 1}}
}

mat_translation :: proc(x, y, z: f32) -> Mat {
	return Mat{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {x, y, z, 1}}
}

// Rotation by angle about axis (normalized here), as D3DXMatrixRotationAxis.
mat_rotation_axis :: proc(ax, ay, az, angle: f32) -> Mat {
	l := math.sqrt(ax * ax + ay * ay + az * az)
	x, y, z := ax / l, ay / l, az / l
	s, c := x86.sin(angle), x86.cos(angle)
	k := 1 - c
	return Mat {
		{k * x * x + c, k * x * y + s * z, k * x * z - s * y, 0},
		{k * x * y - s * z, k * y * y + c, k * y * z + s * x, 0},
		{k * x * z + s * y, k * y * z - s * x, k * z * z + c, 0},
		{0, 0, 0, 1},
	}
}

// Roll about Z, then pitch about X, then yaw about Y.
mat_yaw_pitch_roll :: proc(yaw, pitch, roll: f32) -> Mat {
	sy, cy := x86.sin(yaw), x86.cos(yaw)
	sp, cp := x86.sin(pitch), x86.cos(pitch)
	sr, cr := x86.sin(roll), x86.cos(roll)
	rz := Mat{{cr, sr, 0, 0}, {-sr, cr, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}}
	rx := Mat{{1, 0, 0, 0}, {0, cp, sp, 0}, {0, -sp, cp, 0}, {0, 0, 0, 1}}
	ry := Mat{{cy, 0, -sy, 0}, {0, 1, 0, 0}, {sy, 0, cy, 0}, {0, 0, 0, 1}}
	return mat_mul(mat_mul(rz, rx), ry)
}

D3DXVec3Normalize :: proc() {
	out, v := arg(0), arg(1)
	x, y, z := rdf(v), rdf(v + 4), rdf(v + 8)
	l := math.sqrt(x * x + y * y + z * z)
	if l == 0 {
		x, y, z = 0, 0, 0
	} else {
		x, y, z = x / l, y / l, z / l
	}
	x86.wr32(out, transmute(u32)x); x86.wr32(out + 4, transmute(u32)y); x86.wr32(out + 8, transmute(u32)z)
	ret(2, out)
}

D3DXMatrixMultiply :: proc() {
	wr_mat(arg(0), mat_mul(rd_mat(arg(1)), rd_mat(arg(2))))
	ret(3, arg(0))
}

D3DXMatrixTranspose :: proc() {
	wr_mat(arg(0), mat_transpose(rd_mat(arg(1))))
	ret(2, arg(0))
}

D3DXMatrixInverse :: proc() {
	out, pdet, m := arg(0), arg(1), arg(2)
	inv, det, ok := mat_inverse(rd_mat(m))
	if !ok {
		ret(3, 0)
		return
	}
	if pdet != 0 {
		x86.wr32(pdet, transmute(u32)det)
	}
	wr_mat(out, inv)
	ret(3, out)
}

D3DXMatrixScaling :: proc() {
	wr_mat(arg(0), mat_scaling(argf(1), argf(2), argf(3)))
	ret(4, arg(0))
}

D3DXMatrixOrthoOffCenterRH :: proc() {
	l, r, b, t, zn, zf := argf(1), argf(2), argf(3), argf(4), argf(5), argf(6)
	wr_mat(arg(0), Mat {
		{2 / (r - l), 0, 0, 0},
		{0, 2 / (t - b), 0, 0},
		{0, 0, 1 / (zn - zf), 0},
		{(l + r) / (l - r), (t + b) / (b - t), zn / (zn - zf), 1},
	})
	ret(7, arg(0))
}

D3DXMatrixPerspectiveFovRH :: proc() {
	fovy, aspect, zn, zf := argf(1), argf(2), argf(3), argf(4)
	ys := 1 / x86.tan(fovy / 2)
	xs := ys / aspect
	wr_mat(arg(0), Mat {
		{xs, 0, 0, 0},
		{0, ys, 0, 0},
		{0, 0, zf / (zn - zf), -1},
		{0, 0, zn * zf / (zn - zf), 0},
	})
	ret(5, arg(0))
}

// ---------------------------------------------------------------- ID3DXMatrixStack

// The stack lives in guest memory because GetTop hands out a pointer to the
// top matrix.
Mat_Stack :: struct {
	buf:   u32, // guest array of cap matrices
	cap:   u32,
	depth: u32, // index of the top matrix
}

mat_stacks: [dynamic]Mat_Stack

MS_METHODS := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", MS_Release},
	{"Pop", MS_Pop}, {"Push", MS_Push}, {"LoadIdentity", MS_LoadIdentity},
	{"LoadMatrix", MS_LoadMatrix}, {"MultMatrix", MS_MultMatrix},
	{"MultMatrixLocal", MS_MultMatrixLocal}, {"RotateAxis", MS_RotateAxis},
	{"RotateAxisLocal", MS_RotateAxisLocal}, {"RotateYawPitchRoll", MS_RotateYawPitchRoll},
	{"RotateYawPitchRollLocal", MS_RotateYawPitchRollLocal}, {"Scale", MS_Scale},
	{"ScaleLocal", MS_ScaleLocal}, {"Translate", MS_Translate},
	{"TranslateLocal", MS_TranslateLocal}, {"GetTop", MS_GetTop},
}

MS_INITIAL_CAP :: 16
MS_MAX_DEPTH :: 4096

D3DXCreateMatrixStack :: proc() {
	out := arg(1)
	buf := heap_alloc(MS_INITIAL_CAP * 64, false)
	wr_mat(buf, MAT_IDENTITY)
	append(&mat_stacks, Mat_Stack{buf, MS_INITIAL_CAP, 0})
	vt := com_vtable("d3dx9_29.dll", "ID3DXMatrixStack", MS_METHODS[:])
	x86.wr32(out, com_new(vt, u32(len(mat_stacks) - 1)))
	ret(2, 0)
}

ms :: proc() -> ^Mat_Stack {
	return &mat_stacks[com_id(arg(0))]
}

ms_top :: proc(s: ^Mat_Stack) -> u32 {
	return s.buf + s.depth * 64
}

MS_Release :: proc() {
	this := arg(0)
	if x86.rd32(this + 4) == 1 {
		s := &mat_stacks[com_id(this)]
		heap_free(s.buf)
		s^ = {}
	}
	com_release()
}

MS_Push :: proc() {
	s := ms()
	if s.depth + 1 >= MS_MAX_DEPTH {
		x86.fatal("ID3DXMatrixStack::Push: depth %d", s.depth)
	}
	if s.depth + 1 == s.cap {
		s.cap *= 2
		s.buf = heap_realloc(s.buf, s.cap * 64, false)
	}
	top := ms_top(s)
	copy(x86.mem[top + 64:top + 128], x86.mem[top:top + 64])
	s.depth += 1
	ret(1, 0)
}

MS_Pop :: proc() {
	s := ms()
	if s.depth > 0 {
		s.depth -= 1
	}
	ret(1, 0)
}

MS_LoadIdentity :: proc() {
	wr_mat(ms_top(ms()), MAT_IDENTITY)
	ret(1, 0)
}

MS_LoadMatrix :: proc() {
	wr_mat(ms_top(ms()), rd_mat(arg(1)))
	ret(2, 0)
}

// top = top * m (global) or m * top (local).
ms_apply :: proc(m: Mat, local: bool) {
	top := ms_top(ms())
	t := rd_mat(top)
	wr_mat(top, local ? mat_mul(m, t) : mat_mul(t, m))
}

MS_MultMatrix :: proc() {ms_apply(rd_mat(arg(1)), false); ret(2, 0)}
MS_MultMatrixLocal :: proc() {ms_apply(rd_mat(arg(1)), true); ret(2, 0)}

MS_RotateAxis :: proc() {
	v := arg(1)
	ms_apply(mat_rotation_axis(rdf(v), rdf(v + 4), rdf(v + 8), argf(2)), false)
	ret(3, 0)
}

MS_RotateAxisLocal :: proc() {
	v := arg(1)
	ms_apply(mat_rotation_axis(rdf(v), rdf(v + 4), rdf(v + 8), argf(2)), true)
	ret(3, 0)
}

MS_RotateYawPitchRoll :: proc() {ms_apply(mat_yaw_pitch_roll(argf(1), argf(2), argf(3)), false); ret(4, 0)}
MS_RotateYawPitchRollLocal :: proc() {ms_apply(mat_yaw_pitch_roll(argf(1), argf(2), argf(3)), true); ret(4, 0)}
MS_Scale :: proc() {ms_apply(mat_scaling(argf(1), argf(2), argf(3)), false); ret(4, 0)}
MS_ScaleLocal :: proc() {ms_apply(mat_scaling(argf(1), argf(2), argf(3)), true); ret(4, 0)}
MS_Translate :: proc() {ms_apply(mat_translation(argf(1), argf(2), argf(3)), false); ret(4, 0)}
MS_TranslateLocal :: proc() {ms_apply(mat_translation(argf(1), argf(2), argf(3)), true); ret(4, 0)}

MS_GetTop :: proc() {
	ret(1, ms_top(ms()))
}
