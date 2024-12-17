type(ML620909)
model	large

;U16 Virtual Machine for running external code
;General design:
;Virtual Instruction Pointer: SP	Virtual Stack Pointer: ER8	Working Register: ER10 (generally xr8 is less accessed than xr12 since they are used for stack addressing, or xr0 since they are used for passing arguments.)
;using 16-bit code segment register and data segment register (for virtual memory accessing)
;emulate VCSR, VDSR, VLCSR, VLR, VXR8 in internal ram
;separate internal ram into code segment, virtual memory segment, local ram segment and stack segment.
;use 32-bit virtual ram pointer, where low 16 bits represents the physical address in the virtual memory segment of the internal ram. Virtual memory access should be prefixed to identify data segment. Local ram accessing should not be prefixed since segment switching is handled in prefix.
;use 32-bit instruction pointer, where low 16 bits point to the physical address in the code segment of the internal ram. Conditional branch and register calls only allows jumping to the same segment. Use long jump to switch segment.
;use SWI0 to handle exceptions. SWI1 for switching code segment, SWI2 for switching data segment.
;implement malloc and free to handle virtual memory allocating. malloc should return a 32-bit pointer pointing to the virtual memory. Do not use malloc for accessing reserved local ram.
;When doing data transfer between data segments, use local ram as buffer. Do not directly transfer between different segments since memory access to a different data segment will reload the whole virtual memory segment from external storage.
;it's recommended to cache frequently accessed data in local ram segment.

;global variables
VCSR	EQU	09000h
VDSR	EQU	09002h
VLCSR	EQU	09004h
VLR	EQU	09006h
VER8	EQU	09008h
VER10	EQU	0900Ah
TMP	EQU	0900Ch

;SWI 0 handler
;raise exceptions
;in: er0-exception code er2-argument
_SWI_0:
	rti

;SWI 1 handler
;Change current code segment
;in: er10-pointer to target virtual address (big endian)
;out: er10-low 16 bits of the target virtual address
_SWI_1:
	push	ea
	push	er8
	push	xr12

	lea	[er10]
	l	xr8,	[ea]
	l	er12,	VCSR
	cmp	er12,	er8
	beq	swi1_ret

	push	qr0
	st	er8,	VCSR
	;calls a function to load the target code segment from external storage to allocated region of the internal ram.
	mov	er0,	er8
	bl	reload_code_segment
	pop	qr0
	
swi1_ret:
	pop	xr12
	pop	er8
	pop	ea
	rti

;example for a virtual instruction handler:
_nop:
	pop	er10	;1 cycle. Stack operation doesn't set flags.
	b	er10	;2 cycles. Minimum extra cycles count possible in each virtual instruction handler is 3. An alternate in SMALL model is using POP PC, which also takes 3 cycles.

_bge:
	pop	er10	;branch target
	blt	skip	;binvcond
	mov	sp,	er10
skip:
	pop	er10
	b	er10

;jump to the same segment
_bal:
	pop	er10
	mov	sp,	er10
	pop	er10
	b	er10

_b_er0:
	mov	sp,	er0
	pop	er10
	b	er10

;long jump
_b:
	mov	er10,	sp
	mov	sp,	er8
	swi	#1
	mov	sp,	er10
	pop	er10
	b	er10

_bl:
	mov	er10,	sp
	mov	sp,	er8
	mov	r8,	psw
	push	r8
	l	er8,	VCSR
	st	er8,	VLCSR
	mov	er8,	er10
	add	er8,	#4
	st	er8,	VLR
	pop	psw
	mov	er8,	sp
	swi	#1
	mov	sp,	er10
	pop	er10
	b	er10

_rt:
	mov	sp,	er8
	mov	r8,	psw
	mov	r10,	#byte1 VLCSR
	mov	r11,	#byte2 VLCSR
	mov	psw,	r8
	mov	er8,	sp
	swi	#1
	mov	sp,	er10
	pop	er10
	b	er10

_push_lr:
	mov	er10,	sp
	st	er10,	TMP
	mov	sp,	er8
	mov	r8,	psw
	l	er10,	VLR
	push	er10
	l	er10,	VLCSR
	push	er10
	l	er10,	TMP
	mov	psw,	r8
	mov	er8,	sp
	mov	sp,	er10
	pop	er10
	b	er10

_pop_pc:
	mov	sp,	er8
	mov	er10,	sp
	swi	#1
	add	sp,	#4
	mov	er8,	sp
	mov	sp,	er10
	pop	er10
	b	er10

_pop_lr:
	mov	er10,	sp
	mov	sp,	er8
	pop	er8
	st	er8,	VLCSR
	pop	er8
	st	er8,	VLR
	mov	er8,	sp
	mov	sp,	er10
	pop	er10
	b	er10

_syscall:
	mov	er10,	sp
	mov	sp,	er8
	st	er10,	TMP
	bl	_do_syscall
	st	er8,	VER8
	st	er10,	VER10
	mov	r8,	psw
	l	er10,	TMP
	add	er10,	#4
	mov	psw,	r8
	mov	er8,	sp
	mov	sp,	er10
	pop	er10
	b	er10

_do_syscall:
	mov	r8,	psw
	push	r8
	l	er8,	[er10]
	l	er10,	02h[er10]
	pop	psw
	push	xr8
	mov	r8,	psw
	push	r8
	l	er8,	VER8
	l	er10,	VER10
	pop	psw
	pop	pc

_push_qr0:
	mov	er10,	sp
	mov	sp,	er8
	push	qr0
	mov	er8,	sp
	mov	sp,	er10
	pop	er10
	b	er10
