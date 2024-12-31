type(ML620909)
model	large

;U16 Virtual Machine for running external code

;General design:
;Virtual Instruction Pointer: SP	Working Register: XR8 (generally xr8 is less accessed than xr12 since they are used for stack addressing, or xr0 since they are used for passing arguments.)
;using 16-bit code segment register, 15-bit data segment register (for virtual memory accessing) and 15-bit stack segment register (for stack virtualization).
;emulate VCSR, VDSR, VSSR, VLCSR, VLR, VXR8 and VSP in internal ram. To make virtual stack addressing easier, each word-sized general register (ERn) is equipped with an additional word-sized register (SERn) to hold stack segment index. 
;separate internal ram into code segment, virtual memory segment, local ram segment and stack segment. The memory map for each user program could be customized.
;use 32-bit virtual ram pointer, where low 16 bits represents the physical address in the virtual memory segment of the internal ram. Virtual memory access should be prefixed to identify data segment. Local ram accessing should not be prefixed since segment switching is handled in prefix.
;use 32-bit virtual stack pointer, where low 16 bits represents the physical address in the stack segment of the internal ram. 8 bytes of ram should be reserved at the beginning and end of the stack segment to avoid overflow/underflow.
;use 32-bit instruction pointer, where low 16 bits point to the physical address in the code segment of the internal ram. Conditional branch and register calls only allows jumping to the same segment. Use long jump to switch segment.
;To make memory addressing easier, MSB of 16-bit form data segment register is fixed to 0, while stack segment register fixed to 1.
;use SWI0 to handle exceptions. SWI1 for switching code segment, SWI2 for switching data/stack segment on load/store and SWI3 for switching stack segment on push/pop.
;`L/ST Rn/ERn, Disp16[BP/FP]` instructions are implemented for accessing virtual stack memory without having to switch stack segment. 
;implement malloc and free to handle virtual memory allocating. malloc should return a 32-bit pointer pointing to the virtual memory. Do not use malloc for accessing reserved local ram.
;When doing data transfer between data segments, use local ram as buffer. Do not directly transfer between different segments since memory access to a different data segment will reload the whole virtual memory segment from external storage.
;it's recommended to cache frequently accessed data in local ram segment.

;virtual registers
VXR8	EQU	09000h
VER8	EQU	09000h
VER10	EQU	09002h
VLR	EQU	09004h
VLCSR	EQU	09006h
VCSR	EQU	09008h
VDSR	EQU	0900Ah
VSSR	EQU	0900Ch
VSREGS	EQU	09010h
VSP	EQU	09020h

;physical memory map info
CS_START	EQU	09024h
CS_END	EQU	09026h
DS_START	EQU	09028h
DS_END	EQU	0902Ah
SS_START	EQU	0902Ch
SS_END	EQU	0902Eh

;PSW backup
_PSW	EQU	0900Eh

;A flag to identify if the cpu is running in virtualized mode
VM_RUNNING	EQU	0900Fh

;register backup for interrupt handlers
TMP	EQU	09030h

;stack mamory reserved for external storage access
LOCAL_STACK	EQU	09100h

;user-registered exception handler
;exception handlers should return a boolean value, true if exception handled successfully, false to forward to default handler
_EXCEPTION_HANDLER	EQU	09040h
_EXCEPTION_HANDLER_CSR	EQU	09042h
_USE_CUSTOM_EXCEPTION_HANDLER	EQU	09043h	;boolean value

extrn code	:	reload_code_segment
extrn code	:	reload_data_segment
extrn code	:	reload_stack_segment
extrn code	:	vmem_byte_store
extrn code	:	vmem_word_store
extrn code	:	vmem_byte_load
extrn code	:	vmem_word_load

extrn number	:	EXCEPTION_STACK_OVERFLOW
extrn number	:	EXCEPTION_STACK_UNDERFLOW

;helper function to call a pointer in stack
__stack_call:
	pop	pc

;BP/FP addressing instructions are implemented here in case handler segment grows too large
vstack_load_store macro isload, regsize, regidx
	local overflow, _underflow, underflow, _external, external, loop1, loop2
	if isload
		mov	r10,	psw
	endif
	st	r10,	_PSW
	st	er0,	TMP
	if !isload
		if regsize == 1
			st	r8,	TMP + 4
		else
			st	er8,	TMP + 4
		endif
	endif
	pop	er8
	if regidx == 12
		add	er8,	bp
	else
		add	er8,	fp
	endif
	l	er10,	SS_START
	cmp	er8,	er10
	blt	overflow
	l	er10,	SS_END
	cmp	er8,	er10
	bge	underflow
	l	er10,	VSREGS + regidx
	l	er0,	VSSR
	cmp	er10,	er0
	bne	_external
	if !isload
		if regsize == 1
			l	r0,	TMP + 4
			st	r0,	[er8]
		else
			l	er0,	TMP + 4
			st	er0,	[er8]
		endif
	endif
	l	er0,	TMP
	l	r10,	_PSW
	mov	psw,	r10
	if isload
		l	r8,	[er8]
	else
		l	er8,	[er8]
	endif
	rt

overflow:
	add	sp,	#-2
	pop	er0
	mov	er0,	er0
	bps	_underflow
	st	er2,	TMP + 2
	l	er0,	SS_END
	l	er2,	VSREGS + regidx
	sub	r0,	r10
	subc	r1,	r11
loop1:
	add	er2,	#-1
	add	er8,	er0
	cmp	er8,	er10
	blt	loop1
	l	er0,	VSSR
	cmp	er2,	er0
	bne	external
	if !isload
		if regsize == 1
			l	r0,	TMP + 4
			st	r0,	[er8]
		else
			l	er0,	TMP + 4
			st	er0,	[er8]
		endif
	endif
	l	er0,	TMP
	l	er2,	TMP + 2
	l	r10,	_PSW
	mov	psw,	r10
	if isload
		l	r8,	[er8]
	else
		l	er8,	[er8]
	endif
	rt

_underflow:
	l	er10,	SS_END
underflow:
	st	er2,	TMP + 2
	l	er0,	SS_START
	l	er2,	VSREGS + regidx
	sub	r0,	r10
	subc	r1,	r11
loop2:
	add	er2,	#1
	add	er8,	er0
	cmp	er8,	er10
	bge	loop2
	l	er0,	VSSR
	cmp	er2,	er0
	bne	external
	if !isload
		if regsize == 1
			l	r0,	TMP + 4
			st	r0,	[er8]
		else
			l	er0,	TMP + 4
			st	er0,	[er8]
		endif
	endif
	l	er0,	TMP
	l	er2,	TMP + 2
	l	r10,	_PSW
	mov	psw,	r10
	if isload
		l	r8,	[er8]
	else
		l	er8,	[er8]
	endif
	rt

_external:
	st	er2,	TMP + 2
	mov	er2,	er10
external:
	di
	mov	er0,	er8
	mov	er10,	sp
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	lr
	if isload
		if regsize == 1
			bl	vmem_byte_load
			mov	r8,	r0
		else
			bl	vmem_word_load
			mov	er8,	er0
		endif
	else
		if regsize == 1
			l	r8,	TMP + 4
			push	r8
			bl	vmem_byte_store
		else
			l	er8,	TMP + 4
			push	er8
			bl	vmem_word_store
		endif
		add	sp,	#2
	endif
	pop	lr
	mov	sp,	er10
	l	er0,	TMP
	l	er2,	TMP + 2
	l	r10,	_PSW
	mov	psw,	r10
	if isload
		if regsize == 1
			mov	r8,	r8
		else
			mov	er8,	er8
		endif
	endif
	rt
endm

;helper function for `L Rn, Disp16[BP]` instructions
__vstack_byte_load_bp:
	vstack_load_store 1, 1, 12

;helper function for `L Rn, Disp16[FP]` instructions
__vstack_byte_load_fp:
	vstack_load_store 1, 1, 14

;helper function for `L ERn, Disp16[BP]` instructions
__vstack_word_load_bp:
	vstack_load_store 1, 2, 12

;helper function for `L ERn, Disp16[FP]` instructions
__vstack_word_load_fp:
	vstack_load_store 1, 2, 14

;helper function for `ST Rn, Disp16[BP]` instructions
__vstack_byte_store_bp:
	vstack_load_store 0, 1, 12

;helper function for `ST Rn, Disp16[FP]` instructions
__vstack_byte_store_fp:
	vstack_load_store 0, 1, 14

;helper function for `ST ERn, Disp16[BP]` instructions
__vstack_word_store_bp:
	vstack_load_store 0, 2, 12

;helper function for `ST ERn, Disp16[FP]` instructions
__vstack_word_store_fp:
	vstack_load_store 0, 2, 14

;helper function for `ADD SP, #imm16` instruction
__vstack_vsp_addition:
	mov	r10,	psw
	st	r10,	_PSW
	pop	er8
	l	er10,	VSP
	add	er8,	er10
	l	er10,	SS_START
	cmp	er8,	er10
	blt	vsp_add_overflow
	l	er10,	SS_END
	cmp	er8,	er10
	bge	vsp_add_underflow
	st	er8,	VSP
	l	r10,	_PSW
	mov	psw,	r10
	rt

vsp_add_overflow:
	st	er0,	TMP
	st	er2,	TMP + 2
	add	sp,	#-2
	pop	er0
	mov	er0,	er0
	bps	_vsp_add_underflow
	l	er0,	SS_END
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vsp_add_loop1:
	add	er2,	#-1
	add	er8,	er0
	cmp	er8,	er10
	blt	vsp_add_loop1
	st	er8,	VSP
	st	er2,	VSP + 2
	l	er0,	TMP
	l	er2,	TMP + 2
	l	r10,	_PSW
	mov	psw,	r10
	rt

_vsp_add_underflow:
	l	er10,	SS_END
vsp_add_underflow:
	l	er0,	SS_START
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vsp_add_loop2:
	add	er2,	#1
	add	er8,	er0
	cmp	er8,	er10
	bge	vsp_add_loop2
	st	er8,	VSP
	st	er2,	VSP + 2
	l	er0,	TMP
	l	er2,	TMP + 2
	l	r10,	_PSW
	mov	psw,	r10
	rt

;SWI 0 handler
;raise exceptions
;in: er0-exception code er2-argument
_SWI_0:
	push	elr,epsw,lr,ea
	push	qr8
	push	xr4
	tb	_USE_CUSTOM_EXCEPTION_HANDLER.0
	beq	default_handler
	l	er4,	_EXCEPTION_HANDLER
	l	r6,	_EXCEPTION_HANDLER_CSR
	push	r6
	push	er4
	bl	__stack_call
	mov	r0,	r0
	beq	default_handler
exception_retn:
	pop	xr4
	pop	qr8
	pop	ea,lr,psw,pc

default_handler:
	bal	exception_retn

;SWI 1 handler
;Change current code segment
;in: er8-pointer to target virtual address
_SWI_1:
	mov	r10,	#byte1 LOCAL_STACK
	mov	r11,	#byte2 LOCAL_STACK
	mov	sp,	er10
	push	ea
	push	xr0
	lea	[er8]
	l	xr8,	[ea]
	l	er0,	VCSR
	cmp	er10,	er0
	bne	do_csr_switch
	pop	xr0
	pop	ea
	mov	sp,	er8
	rti

do_csr_switch:
	st	er10,	VCSR
	;calls a function to load the target code segment from external storage to allocated region of the internal ram.
	mov	er0,	er10
	bl	reload_code_segment
	pop	xr0
	pop	ea
	mov	sp,	er8
	rti

;SWI 2 handler
;Change current data/stack segment
;in: er8-target data/stack segment
_SWI_2:
	tb	r9.7
	bne	ssr_switch
	l	er10,	VDSR
	cmp	er8,	er10
	bne	do_dsr_switch
	rti

ssr_switch:
	l	er10,	VSSR
	cmp	er8,	er10
	bne	do_ssr_switch
	rti

do_dsr_switch:
	st	er8,	VDSR
	mov	er8,	sp
	st	er8,	TMP
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	ea
	push	xr0
	;calls a function to save and load the target data segment from external storage.
	mov	er0,	er10
	l	er2,	VDSR
	l	er10,	TMP
	bl	reload_data_segment
	pop	xr0
	pop	ea
	mov	sp,	er10
	rti

do_ssr_switch:
	st	er8,	VSSR
	mov	er8,	sp
	st	er8,	TMP
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	ea
	push	xr0
	;calls a function to save and load the target stack segment from external storage.
	mov	er0,	er10
	l	er2,	VSSR
	l	er8,	VSP
	l	er10,	TMP
	bl	reload_stack_segment
	pop	xr0
	pop	ea
	mov	sp,	er10
	rti

;SWI 3 handler
;Check stack overflow/underflow
;out: er8-low 16 bits of vsp
_SWI_3:
	l	er8,	VSP
	l	er10,	SS_START
	cmp	er8,	er10
	blt	ss_overflow
	l	er10,	SS_END
	cmp	er8,	er10
	bge	ss_underflow
	l	er8,	VSP + 2
	l	er10,	VSSR
	cmp	er8,	er10
	bne	do_ssr_switch
	l	er8,	VSP
	rti

ss_overflow:
	mov	er8,	sp
	st	er8,	TMP
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	ea
	push	xr0
	l	er8,	VSP
	l	er0,	SS_END
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vstack_fix_loop1:
	add	er2,	#-1
	add	er8,	er0
	cmp	er8,	er10
	blt	vstack_fix_loop1
	st	er8,	VSP
	st	er2,	VSP + 2
	l	er0,	VSSR
	cmp	er2,	er0
	beq	vstack_fix_retn
	tb	r3.7
	beq	_vstack_overflow
	st	er2,	VSSR
	bl	reload_stack_segment

vstack_fix_retn:
	pop	xr0
	pop	ea
	l	er10,	TMP
	mov	sp,	er10
	rti

ss_underflow:
	mov	er8,	sp
	st	er8,	TMP
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	ea
	push	xr0
	l	er8,	VSP
	l	er0,	SS_START
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vstack_fix_loop2:
	add	er2,	#1
	add	er8,	er0
	cmp	er8,	er10
	bge	vstack_fix_loop2
	st	er8,	VSP
	st	er2,	VSP + 2
	l	er0,	VSSR
	cmp	er2,	er0
	beq	vstack_fix_retn
	tb	r3.7
	beq	_vstack_underflow
	st	er2,	VSSR
	bl	reload_stack_segment
	bal	vstack_fix_retn

_vstack_overflow:
	mov	r0,	#byte1 EXCEPTION_STACK_OVERFLOW
	mov	r1,	#byte2 EXCEPTION_STACK_OVERFLOW
	bal	vstack_fix_raise_exception

_vstack_underflow:
	mov	r0,	#byte1 EXCEPTION_STACK_UNDERFLOW
	mov	r1,	#byte2 EXCEPTION_STACK_UNDERFLOW

vstack_fix_raise_exception:
	push	elr,epsw
	swi	#0
	pop	r0
	mov	epsw,	r0
	pop	xr0
	mov	elr,	er0
	mov	ecsr,	r2
	bal	vstack_fix_retn

;VM instruction handler segment
cseg #1 at 00000h

;fetch the next virtual instruction and jump to handler.
;placed at the end of each handler.
fetch macro
	pop	er8	;1 cycle. Stack operation doesn't set flags.
	b	er8	;2 cycles. Minimum extra cycles count possible in each virtual instruction handler is 3. An alternate in SMALL model is using POP PC, which also takes 3 cycles.
endm

;handler for `insn rn, rm` style instructions
insn_rn_rm macro insn
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		idx1 set 0
		irp rm, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
			$ set(unhandled)
			if idx0 >= 8 && idx0 < 12
				if idx0 == idx1
					l	r8,	VXR8 + idx0 - 8
					insn	r8,	r8
					st	r8,	VXR8 + idx0 - 8
				elseif (idx0 & 0Fh) == (idx1 & 0Fh)
					l	er8,	VXR8 + (idx0 & 0Fh) - 8
					if idx0 < idx1
						insn	r8,	r9
						st	r8,	VXR8 + idx0 - 8
					else
						insn	r9,	r8
						st	r9,	VXR8 + idx0 - 8
					endif
				elseif idx1 >= 8 && idx1 < 12
					l	r8,	VXR8 + idx0 - 8
					l	r9,	VXR8 + idx1 - 8
					insn	r8,	r9
					st	r8,	VXR8 + idx0 - 8
				else
					l	r8,	VXR8 + idx0 - 8
					insn	r8,	rm
					st	r8,	VXR8 + idx0 - 8
				endif
				$ reset(unhandled)
			elseif idx1 >= 8 && idx1 < 12
				l	r8,	VXR8 + idx1 - 8
			endif
			$ if(unhandled)
				insn	rn,	rm
			$ endif
			fetch
			idx1 set idx1 + 1
		endm
		idx0 set idx0 + 1
	endm
endm

insn_rn_rm_saveflags macro insn
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		idx1 set 0
		irp rm, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
			$ set(unhandled)
			if idx0 >= 8 && idx0 < 12
				mov	r10,	psw
				if idx0 == idx1
					l	r8,	VXR8 + idx0 - 8
					mov	psw,	r10
					insn	r8,	r8
					st	r8,	VXR8 + idx0 - 8
				elseif (idx0 & 0Fh) == (idx1 & 0Fh)
					l	er8,	VXR8 + (idx0 & 0Fh) - 8
					mov	psw,	r10
					if idx0 < idx1
						insn	r8,	r9
						st	r8,	VXR8 + idx0 - 8
					else
						insn	r9,	r8
						st	r9,	VXR8 + idx0 - 8
					endif
				elseif idx1 >= 8 && idx1 < 12
					l	r8,	VXR8 + idx0 - 8
					l	r9,	VXR8 + idx1 - 8
					mov	psw,	r10
					insn	r8,	r9
					st	r8,	VXR8 + idx0 - 8
				else
					l	r8,	VXR8 + idx0 - 8
					mov	psw,	r10
					insn	r8,	rm
					st	r8,	VXR8 + idx0 - 8
				endif
				$ reset(unhandled)
			elseif idx1 >= 8 && idx1 < 12
				mov	r10,	psw
				l	r8,	VXR8 + idx1 - 8
				mov	psw,	r10
			endif
			$ if(unhandled)
				insn	rn,	rm
			$ endif
			fetch
			idx1 set idx1 + 1
		endm
		idx0 set idx0 + 1
	endm
endm

;handler for `insn ern, erm` style instructions
insn_ern_erm macro insn
	idx0 set 0
	irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
		idx1 set 0
		irp erm, <er0, er2, er4, er6, er8, er8, er12, er14>
			$ set(unhandled)
			if idx0 >= 8 && idx0 < 12
				l	er8,	VXR8 + idx0 - 8
				if idx0 == idx1
					insn	er8,	er8
					st	er8,	VXR8 + idx0 - 8
				elseif idx1 >= 8 && idx1 < 12
					l	er10,	VXR8 + idx1 - 8
					insn	er8,	er10
					st	er8,	VXR8 + idx0 - 8
				else
					insn	er8,	erm
					st	er8,	VXR8 + idx0 - 8
				endif
				$ reset(unhandled)
			else
				if idx1 >= 8 && idx1 < 12
					l	er8,	VXR8 + idx1 - 8
				endif
			endif
			$ if(unhandled)
				insn	ern,	erm
			$ endif
			fetch
			idx1 set idx1 + 2
		endm
		idx0 set idx0 + 2
	endm
endm

;handler for `insn rn, #imm8` style instructions
insn_rn_imm8 macro insn
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		pop	r8
		if idx0 >= 8 && idx0 < 12
			l	r9,	VXR8 + idx0 - 8
			insn	r9,	r8
			st	r9,	VXR8 + idx0 - 8
		else
			insn	rn,	r8
		endif
		fetch
		idx0 set idx0 + 1
	endm
endm

insn_rn_imm8_saveflags macro insn
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		pop	r8
		if idx0 >= 8 && idx0 < 12
			mov	r10,	psw
			l	r9,	VXR8 + idx0 - 8
			mov	psw,	r10
			insn	r9,	r8
			st	r9,	VXR8 + idx0 - 8
		else
			insn	rn,	r8
		endif
		fetch
		idx0 set idx0 + 1
	endm
endm

;handler for `insn rn` style instructions
insn_rn macro insn
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx0 >= 8 && idx0 < 12
			mov	r10,	psw
			l	r8,	VXR8 + idx0 - 8
			mov	psw,	r10
			insn	r8
			st	r8,	VXR8 + idx0 - 8
		else
			insn	rn
		endif
		fetch
		idx0 set idx0 + 1
	endm
endm

;handler for register-irrelevant instructions
insn_misc macro insn
	insn
	fetch
endm

insn_ern_erm add
insn_rn_rm add
insn_rn_imm8 add
insn_rn_rm addc
insn_rn_imm8 addc
insn_rn_rm and
insn_rn_imm8 and
insn_misc brk
insn_ern_erm cmp
insn_rn_rm cmp
insn_rn_imm8 cmp
insn_rn_rm cmpc
insn_rn_imm8 cmpc
insn_misc cplc
insn_rn daa
insn_rn das
insn_misc di
insn_misc ei
insn_ern_erm mov
insn_rn_rm mov
fetch	;nop
insn_rn_rm or
insn_rn_imm8 or
insn_misc rc
insn_misc sc
insn_rn_rm_saveflags sll
insn_rn_imm8_saveflags sll
insn_rn_rm_saveflags sllc
insn_rn_imm8_saveflags sllc
insn_rn_rm_saveflags sra
insn_rn_imm8_saveflags sra
insn_rn_rm_saveflags srl
insn_rn_imm8_saveflags srl
insn_rn_rm_saveflags srlc
insn_rn_imm8_saveflags srlc
insn_rn_rm sub
insn_rn_rm subc
insn_rn_rm xor
insn_rn_imm8 xor

;ADD ERn, #imm16
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	pop	er10
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
		add	er8,	er10
		st	er8,	VXR8 + idx0 - 8
	else
		add	ern,	er10
	endif
	fetch
	idx0 set idx0 + 2
endm

;ADD SP, #imm16
_add_sp_imm:
	bl	__vstack_vsp_addition
	fetch

;DEC [EA]
_dec_ea:
	dec	[ea]
	fetch

;INC [EA]
_inc_ea:
	inc	[ea]
	fetch

;EXTBW ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
		extbw	er8
		st	er8,	VXR8 + idx0 - 8
	else
		extbw	ern
	endif
	fetch
	idx0 set idx0 + 2
endm

;DIV ERn, Rm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx1 set 0
	irp rm, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx0 >= 8 && idx0 < 12
			mov	r11,	psw
			l	er8,	VXR8 + idx0 - 8
			if idx0 == idx1
				mov	psw,	r11
				div	er8,	r8
			elseif idx0 == idx1 - 1
				mov	psw,	r11
				div	er8,	r9
			elseif idx1 >= 8 && idx1 < 12
				l	r10,	VXR8 + idx1 - 8
				mov	psw,	r11
				div	er8,	r10
				st	r10,	VXR8 + idx1 - 8
			else
				mov	psw,	r11
				div	er8,	rm
			endif
			st	er8,	VXR8 + idx0 - 8
		elseif idx1 >= 8 && idx1 < 12
			mov	r10,	psw
			l	r8,	VXR8 + idx1 - 8
			mov	psw,	r10
			div	ern,	r8
			st	r8,	VXR8 + idx1 - 8
		else
			div	ern,	rm
		endif
		fetch
		idx1 set idx1 + 1
	endm
	idx0 set idx0 + 2
endm

;MUL ERn, Rm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx1 set 0
	irp rm, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
		$ set(unhandled)
		if idx0 >= 8 && idx0 < 12
			mov	r11,	psw
			if idx0 == idx1
				l	r8,	VXR8 + idx0 - 8
				mov	psw,	r11
				mul	er8,	r8
				st	er8,	VXR8 + idx0 - 8
			elseif idx0 == idx1 - 1
				l	er8,	VXR8 + idx0 - 8
				mov	psw,	r11
				mul	er8,	r9
				st	er8,	VXR8 + idx0 - 8
			elseif idx1 >= 8 && idx1 < 12
				l	r8,	VXR8 + idx0 - 8
				l	r10,	VXR8 + idx1 - 8
				mov	psw,	r11
				mul	er8,	r10
				st	er8,	VXR8 + idx0 - 8
			else
				l	r8,	VXR8 + idx0 - 8
				mov	psw,	r11
				mul	er8,	rm
				st	er8,	VXR8 + idx0 - 8
			endif
			$ reset(unhandled)
		elseif idx1 >= 8 && idx1 < 12
			mov	r10,	psw
			l	r8,	VXR8 + idx1 - 8
			mov	psw,	r10
		endif
		$ if(unhandled)
			mul	ern,	rm
		$ endif
		fetch
		idx1 set idx1 + 1
	endm
	idx0 set idx0 + 2
endm

;LEA Dadr
_lea_dadr:
	pop	ea
	fetch

;LEA [ERm]
idx0 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	er8,	VXR8 + idx0 - 8
		lea	[er8]
		mov	psw,	r10
	else
		lea	[erm]
	endif
	fetch
	idx0 set idx0 + 2
endm

;LEA Disp16[ERm]
idx0 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	pop	er8
	if idx0 >= 8 && idx0 < 12
		st	r10,	_PSW
		l	er10,	VXR8 + idx0 - 8
		add	er8,	er10
		lea	[er8]
		l	r10,	_PSW
	else
		add	er8,	erm
		lea	[er8]
	endif
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

;MOV ERn, #imm16
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er8, er12, er14>
	if idx0 >= 8 && idx0 < 12
		pop	er8
		st	er8,	VXR8 + idx0 - 8
	else
		pop	ern
	endif
	mov	ern,	ern
	fetch
	idx0 set idx0 + 2
endm

;MOV Rn, #imm8
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		pop	r8
		st	r8,	VXR8 + idx0 - 8
	else
		pop	rn
	endif
	mov	rn,	rn
	fetch
	idx0 set idx0 + 1
endm

;MOV ERn, SP
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	er8,	VSP
		st	er8,	VXR8 + idx0 - 8
	else
		l	ern,	VSP
	endif
	l	er8,	VSP + 2
	st	er8,	VSREGS + idx0
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

;MOV SP, ERm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
		st	er8,	VSP
	else
		st	ern,	VSP
	endif
	l	er8,	VSREGS + idx0
	st	er8,	VSP + 2
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

;MOV ERn, VSERm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	irp vserm, <0, 2, 4, 6, 8, 10, 12, 14>
		mov	r10,	psw
		if idx0 >= 8 && idx0 < 12
			l	er8,	VSREGS + vserm
			st	er8,	VXR8 + idx0 - 8
		else
			l	ern,	VSREGS + vserm
		endif
		mov	psw,	r10
		fetch
	endm
	idx0 set idx0 + 2
endm

;MOV VSERn, ERm
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	irp vsern, <0, 2, 4, 6, 8, 10, 12, 14>
		if idx1 >= 8 && idx1 < 12
			mov	r10,	psw
			l	er8,	VXR8 + idx1 - 8
			st	er8,	VSREGS + vsern
			mov	psw,	r10
		else
			st	erm,	VSREGS + vsern
		endif
		fetch
	endm
	idx1 set idx1 + 2
endm

;NEG Rn
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		l	r8,	VXR8 + idx0 - 8
		neg	r8
		st	r8,	VXR8 + idx0 - 8
	else
		neg	rn
	endif
	fetch
	idx0 set idx0 + 1
endm

irp insn, <rb, sb>
	;RB Dbitadr
	;SB Dbitadr
	irp bitidx, <0, 1, 2, 3, 4, 5, 6, 7>
		pop	er8
		mov	r11,	psw
		l	r10,	[er8]
		mov	psw,	r11
		insn	r10.bitidx
		st	r10,	[er8]
		fetch
	endm

	;RB Rn.bit_offset
	;SB Rn.bit_offset
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		irp bitidx, <0, 1, 2, 3, 4, 5, 6, 7>
			if idx0 >= 8 && idx0 < 12
				mov	r10,	psw
				l	r8,	VXR8 + idx0 - 8
				mov	psw,	r10
				insn	r8.bitidx
				st	r8,	VXR8 + idx0 - 8
			else
				insn	rn.bitidx
			endif
			fetch
		endm
		idx0 set idx0 + 1
	endm
endm

;TB Dbitadr
irp bitidx, <0, 1, 2, 3, 4, 5, 6, 7>
	pop	er8
	mov	r11,	psw
	l	r10,	[er8]
	mov	psw,	r11
	tb	r10.bitidx
	fetch
endm

;TB Rn.bit_offset
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	irp bitidx, <0, 1, 2, 3, 4, 5, 6, 7>
		if idx0 >= 8 && idx0 < 12
			mov	r10,	psw
			l	r8,	VXR8 + idx0 - 8
			mov	psw,	r10
			tb	r8.bitidx
		else
			tb	rn.bitidx
		endif
		fetch
	endm
	idx0 set idx0 + 1
endm

;ST Rn, [ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx1 >= 8 && idx1 < 12
			mov	r11,	psw
			l	er8,	VXR8 + idx1 - 8
			if idx0 == idx1
				st	r8,	[er8]
			elseif idx0 == idx1 - 1
				st	r9,	[er8]
			elseif idx0 >= 8 && idx0 < 12
				l	r10,	VXR8 + idx0 - 8
				st	r10,	[er8]
			else
				st	rn,	[er8]
			endif
			mov	psw,	r11
		elseif idx0 >= 8 && idx0 < 12
			mov	r10,	psw
			l	r8,	VXR8 + idx0 - 8
			st	r8,	[erm]
			mov	psw,	r10
		else
			st	rn,	[erm]
		endif
		fetch
		idx0 set idx0 + 1
	endm
	idx1 set idx1 + 2
endm

;ST ERn, [ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
		if idx1 >= 8 && idx1 < 12
			mov	r10,	psw
			l	er8,	VXR8 + idx1 - 8
			if idx0 == idx1
				st	er8,	[er8]
			elseif idx0 >= 8 && idx0 < 12
				st	r10,	_PSW
				l	er10,	VXR8 + idx0 - 8
				st	er10,	[er8]
				l	r10,	_PSW
			else
				st	ern,	[er8]
			endif
			mov	psw,	r10
		elseif idx0 >= 8 && idx0 < 12
			mov	r10,	psw
			l	er8,	VXR8 + idx0 - 8
			st	er8,	[erm]
			mov	psw,	r10
		else
			st	ern,	[erm]
		endif
		fetch
		idx0 set idx0 + 2
	endm
	idx1 set idx1 + 2
endm

;ST Rn, Disp16[ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx1 >= 8 && idx1 < 12
			mov	r10,	psw
			st	r10,	_PSW
			pop	er8
			l	er10,	VXR8 + idx1 - 8
			add	er8,	er10
			if idx0 == idx1
				st	r10,	[er8]
			elseif idx0 == idx1 - 1
				st	r11,	[er8]
			elseif idx0 >= 8 && idx0 < 12
				l	r10,	VXR8 + idx0 - 8
				st	r10,	[er8]
			else
				st	rn,	[er8]
			endif
			l	r10,	_PSW
		else
			mov	r10,	psw
			pop	er8
			add	er8,	erm
			if idx0 >= 8 && idx0 < 12
				l	r11,	VXR8 + idx0 - 8
				st	r11,	[er8]
			else
				st	rn,	[er8]
			endif
		endif
		mov	psw,	r10
		fetch
		idx0 set idx0 + 1
	endm
	idx1 set idx1 + 2
endm

;ST ERn, Disp16[ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
		mov	r10,	psw
		if idx1 >= 8 && idx1 < 12
			st	r10,	_PSW
			pop	er8
			l	er10,	VXR8 + idx1 - 8
			add	er8,	er10
			if idx0 == idx1
				st	er10,	[er8]
			elseif idx0 >= 8 && idx0 < 12
				l	er10,	VXR8 + idx0 - 8
				st	er10,	[er8]
			else
				st	ern,	[er8]
			endif
			l	r10,	_PSW
		elseif idx0 >= 8 && idx0 < 12
			st	r10,	_PSW
			pop	er8
			add	er8,	erm
			l	er10,	VXR8 + idx0 - 8
			st	er10,	[er8]
			l	r10,	_PSW
		else
			pop	er8
			add	er8,	erm
			st	ern,	[er8]
		endif
		mov	psw,	r10
		fetch
		idx0 set idx0 + 2
	endm
	idx1 set idx1 + 2
endm

;ST Rn, Disp16[BP]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	r8,	VXR8 + idx0 - 8
	else
		mov	r8,	rn
	endif
	bl	__vstack_byte_store_bp
	fetch
	idx0 set idx0 + 1
endm

;ST Rn, Disp16[FP]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	r8,	VXR8 + idx0 - 8
	else
		mov	r8,	rn
	endif
	bl	__vstack_byte_store_fp
	fetch
	idx0 set idx0 + 1
endm

;ST ERn, Disp16[BP]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
	else
		mov	er8,	ern
	endif
	bl	__vstack_word_store_bp
	fetch
	idx0 set idx0 + 2
endm

;ST ERn, Disp16[FP]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
	else
		mov	er8,	ern
	endif
	bl	__vstack_word_store_fp
	fetch
	idx0 set idx0 + 2
endm

;ST Rn, Dadr
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	pop	er8
	if idx0 >= 8 && idx0 < 12
		mov	r11,	psw
		l	r10,	VXR8 + idx0 - 8
		mov	psw,	r11
		st	r10,	[er8]
	else
		st	rn,	[er8]
	endif
	fetch
	idx0 set idx0 + 1
endm

;ST ERn, Dadr
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		mov	r8,	psw
		l	er10,	VXR8 + idx0 - 8
		mov	psw,	r8
		pop	er8
		st	er10,	[er8]
	else
		pop	er8
		st	ern,	[er8]
	endif
	fetch
	idx0 set idx0 + 2
endm

;ST Rn, [EA]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	r8,	VXR8 + idx0 - 8
		mov	psw,	r10
		st	r8,	[ea]
	else
		st	rn,	[ea]
	endif
	fetch
	idx0 set idx0 + 1
endm

;ST Rn, [EA+]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	r8,	VXR8 + idx0 - 8
		mov	psw,	r10
		st	r8,	[ea+]
	else
		st	rn,	[ea+]
	endif
	fetch
	idx0 set idx0 + 1
endm

;ST ERn, [EA]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	er8,	VXR8 + idx0 - 8
		st	er8,	[ea]
		mov	psw,	r10
	else
		st	ern,	[ea]
	endif
	fetch
	idx0 set idx0 + 2
endm

;ST ERn, [EA+]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	er8,	VXR8 + idx0 - 8
		st	er8,	[ea+]
		mov	psw,	r10
	else
		st	ern,	[ea+]
	endif
	fetch
	idx0 set idx0 + 2
endm

;ST XRn, [EA]
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	if idx0 == 8
		mov	r10,	psw
		l	er8,	VER8
		st	er8,	[ea+]
		l	er8,	VER10
		st	er8,	[ea]
		mov	psw,	r10
	else
		st	xrn,	[ea]
	endif
	fetch
	idx0 set idx0 + 4
endm

;ST XRn, [EA+]
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	if idx0 == 8
		mov	r10,	psw
		l	er8,	VER8
		st	er8,	[ea+]
		l	er8,	VER10
		st	er8,	[ea+]
		mov	psw,	r10
	else
		st	xrn,	[ea+]
	endif
	fetch
	idx0 set idx0 + 4
endm

;ST QR0, [EA]
_st_qr0_ea:
	st	qr0,	[ea]
	fetch

;ST QR8, [EA]
_st_qr8_ea:
	mov	r10,	psw
	l	er8,	VER8
	st	er8,	[ea+]
	l	er8,	VER10
	st	er8,	[ea+]
	st	xr12,	[ea]
	mov	psw,	r10
	fetch

;ST QR0, [EA+]
_st_qr0_eap:
	st	qr0,	[ea+]
	fetch

;ST QR8, [EA+]
_st_qr8_eap:
	mov	r10,	psw
	l	er8,	VER8
	st	er8,	[ea+]
	l	er8,	VER10
	st	er8,	[ea+]
	st	xr12,	[ea+]
	mov	psw,	r10
	fetch

;L Rn, [ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er8, er12, er14>
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx1 >= 8 && idx1 < 12
			l	er8,	VXR8 + idx1 - 8
		endif
		if idx0 >= 8 && idx0 < 12
			l	r8,	[erm]
			st	r8,	VXR8 + idx0 - 8
		else
			l	rn,	[erm]
		endif
		fetch
		idx0 set idx0 + 1
	endm
	idx1 set idx1 + 2
endm

;L ERn, [ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er8, er12, er14>
	idx0 set 0
	irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
		if idx1 >= 8 && idx1 < 12
			l	er8,	VXR8 + idx1 - 8
		endif
		if idx0 >= 8 && idx0 < 12
			l	er8,	[erm]
			st	er8,	VXR8 + idx0 - 8
		else
			l	ern,	[erm]
		endif
		fetch
		idx0 set idx0 + 2
	endm
	idx1 set idx1 + 2
endm

;L Rn, Disp16[ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		mov	r10,	psw
		if idx1 >= 8 && idx1 < 12
			st	r10,	_PSW
			pop	er8
			l	er10,	VXR8 + idx1 - 8
			add	er8,	er10
			l	r10,	_PSW
		else
			pop	er8
			add	er8,	erm
		endif
		mov	psw,	r10
		if idx0 >= 8 && idx0 < 12
			l	r8,	[er8]
			st	r8,	VXR8 + idx0 - 8
		else
			l	rn,	[er8]
		endif
		fetch
		idx0 set idx0 + 1
	endm
	idx1 set idx1 + 2
endm

;L ERn, Disp16[ERm]
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx0 set 0
	irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
		mov	r10,	psw
		if idx1 >= 8 && idx1 < 12
			st	r10,	_PSW
			pop	er8
			l	er10,	VXR8 + idx1 - 8
			add	er8,	er10
			l	r10,	_PSW
		else
			pop	er8
			add	er8,	erm
		endif
		mov	psw,	r10
		if idx0 >= 8 && idx0 < 12
			l	er8,	[er8]
			st	er8,	VXR8 + idx0 - 8
		else
			l	ern,	[er8]
		endif
		fetch
		idx0 set idx0 + 2
	endm
	idx1 set idx1 + 2
endm

;L Rn, Disp16[BP]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	bl	__vstack_byte_load_bp
	if idx0 >= 8 && idx0 < 12
		st	r8,	VXR8 + idx0 - 8
	else
		mov	rn,	r8
	endif
	fetch
	idx0 set idx0 + 1
endm

;L Rn, Disp16[FP]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	bl	__vstack_byte_load_fp
	if idx0 >= 8 && idx0 < 12
		st	r8,	VXR8 + idx0 - 8
	else
		mov	rn,	r8
	endif
	fetch
	idx0 set idx0 + 1
endm

;L ERn, Disp16[BP]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	bl	__vstack_word_load_bp
	if idx0 >= 8 && idx0 < 12
		st	er8,	VXR8 + idx0 - 8
	else
		mov	ern,	er8
	endif
	fetch
	idx0 set idx0 + 2
endm

;L ERn, Disp16[FP]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	bl	__vstack_word_load_fp
	if idx0 >= 8 && idx0 < 12
		st	er8,	VXR8 + idx0 - 8
	else
		mov	ern,	er8
	endif
	fetch
	idx0 set idx0 + 2
endm

;L Rn, Dadr
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	pop	er8
	if idx0 >= 8 && idx0 < 12
		l	r8,	[er8]
		st	r8,	VXR8 + idx0 - 8
	else
		l	rn,	[er8]
	endif
	fetch
	idx0 set idx0 + 1
endm

;L ERn, Dadr
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	pop	er8
	if idx0 >= 8 && idx0 < 12
		l	er8,	[er8]
		st	er8,	VXR8 + idx0 - 8
	else
		l	ern,	[er8]
	endif
	fetch
	idx0 set idx0 + 2
endm

;L Rn, [EA]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		l	r8,	[ea]
		st	r8,	VXR8 + idx0 - 8
	else
		l	rn,	[ea]
	endif
	fetch
	idx0 set idx0 + 1
endm

;L Rn, [EA+]
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		l	r8,	[ea+]
		st	r8,	VXR8 + idx0 - 8
	else
		l	rn,	[ea+]
	endif
	fetch
	idx0 set idx0 + 1
endm

;L ERn, [EA]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		l	er8,	[ea]
		st	er8,	VXR8 + idx0 - 8
	else
		l	ern,	[ea]
	endif
	fetch
	idx0 set idx0 + 2
endm

;L ERn, [EA+]
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	if idx0 >= 8 && idx0 < 12
		l	er8,	[ea+]
		st	er8,	VXR8 + idx0 - 8
	else
		l	ern,	[ea+]
	endif
	fetch
	idx0 set idx0 + 2
endm

;L XRn, [EA]
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	if idx0 == 8
		l	xr8,	[ea]
		st	er8,	VER8
		st	er10,	VER10
	else
		l	xrn,	[ea]
	endif
	fetch
	idx0 set idx0 + 4
endm

;L XRn, [EA+]
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	if idx0 == 8
		l	xr8,	[ea+]
		st	er8,	VER8
		st	er10,	VER10
	else
		l	xrn,	[ea+]
	endif
	fetch
	idx0 set idx0 + 4
endm

;L QR0, [EA]
_l_qr0_ea:
	l	qr0,	[ea]
	fetch

;L QR8, [EA]
_l_qr8_ea:
	l	qr8,	[ea]
	st	er8,	VER8
	st	er10,	VER10
	fetch

;L QR0, [EA+]
_l_qr0_eap:
	l	qr0,	[ea+]
	fetch

;L QR8, [EA+]
_l_qr8_eap:
	l	qr8,	[ea+]
	st	er8,	VER8
	st	er10,	VER10
	fetch

;Bcond addr
bcond_handler macro binvcond
	local skip
	pop	er8
	binvcond	skip
	mov	sp,	er8
skip:
	fetch
endm

irp binvcond, <blt, bge, ble, bgt, blts, bges, bles, bgts, beq, bne, bov, bnv, bns, bps>
	bcond_handler binvcond
endm

;BAL addr
;jump to the same segment
_bal:
	pop	er8
	mov	sp,	er8
	fetch

;B ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er8, er12, er14>
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	er8,	VXR8 + idx0 - 8
		mov	psw,	r10
	endif
	mov	sp,	ern
	fetch
	idx0 set idx0 + 2
endm

;B Cadr
;long jump
_b:
	mov	er8,	sp
	swi	#1
	fetch

;BL Cadr
_bl:
	mov	r10,	psw
	l	er8,	VCSR
	st	er8,	VLCSR
	mov	er8,	sp
	add	er8,	#4
	st	er8,	VLR
	mov	psw,	r10
	mov	er8,	sp
	swi	#1
	fetch

;BL ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er8, er12, er14>
	mov	r10,	psw
	l	er8,	VCSR
	st	er8,	VLCSR
	mov	er8,	sp
	st	er8,	VLR
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
	endif
	mov	psw,	r10
	mov	sp,	ern
	fetch
	idx0 set idx0 + 2
endm

;RT
_rt:
	mov	r10,	psw
	mov	r8,	#byte1 VLR
	mov	r9,	#byte2 VLR
	mov	psw,	r10
	swi	#1
	fetch

;SYSCALL Cadr
;calls native function in the ROM
_syscall:
	mov	r8,	psw
	st	r8,	_PSW
	l	er8,	VCSR
	st	er8,	VLCSR
	mov	er8,	sp
	add	er8,	#4
	st	er8,	VLR
	l	er8,	VSP
	mov	er10,	sp
	mov	sp,	er8
	l	er8,	[er10]
	l	er10,	02h[er10]
	push	xr8
	l	r8,	_PSW
	push	r8
	l	er8,	VER8
	l	er10,	VER10
	pop	psw
	bl	__stack_call
	st	er8,	VER8
	st	er10,	VER10
	mov	r10,	psw
	mov	r8,	#byte1 VLR
	mov	r9,	#byte2 VLR
	mov	psw,	r10
	swi	#1
	fetch

;VDSR/VSSR <- ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	mov	r10,	psw
	if idx0 >= 8 && idx0 < 12
		l	er8,	VXR8 + idx0 - 8
	else
		mov	er8,	ern
	endif
	mov	psw,	r10
	swi	#2
	fetch
	idx0 set idx0 + 2
endm

;VDSR/VSSR <- imm16
_mov_dsr_imm16:
	pop	er8
	swi	#2
	fetch

; ;PUSH ELR
; _push_elr:
; 	mov	er10,	sp
; 	mov	sp,	er8
; 	push	elr
; 	mov	er8,	sp
; 	mov	sp,	er10
; 	fetch

; ;PUSH EPSW
; _push_epsw:
; 	mov	er10,	sp
; 	mov	sp,	er8
; 	push	epsw
; 	mov	er8,	sp
; 	mov	sp,	er10
; 	fetch

;PUSH LR
_push_lr:
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	add	er8,	#-2
	l	er10,	VLCSR
	st	er10,	[er8]
	add	er8,	#-2
	l	er10,	VLR
	st	er10,	[er8]
	st	er8,	VSP
	l	r10,	_PSW
	mov	psw,	r10
	fetch

;PUSH EA
_push_ea:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	push	ea
	mov	er8,	sp
	st	er8,	VSP
	mov	sp,	er10
	fetch

;POP EA
_pop_ea:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	pop	ea
	mov	er8,	sp
	st	er8,	VSP
	mov	sp,	er10
	fetch

;POP PSW
_pop_psw:
	swi	#3
	l	r10,	[er8]
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r10
	fetch

;POP LR
_pop_lr:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	pop	er8
	st	er8,	VLR
	pop	er8
	st	er8,	VLCSR
	mov	er8,	sp
	st	er8,	VSP
	mov	sp,	er10
	fetch

;POP PC
_pop_pc:
	swi	#3
	swi	#1
	mov	r10,	psw
	l	er8,	VSP
	add	er8,	#4
	st	er8,	VSP
	mov	psw,	r10
	fetch

;PUSH Rn
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r10, r10, r10, r10, r12, r13, r14, r15>
	swi	#3
	mov	r11,	psw
	if idx0 >= 8 && idx0 < 12
		l	r10,	VXR8 + idx0 - 8
	endif
	add	er8,	#-2
	st	rn,	[er8]
	st	er8,	VSP
	mov	psw,	r11
	fetch
	idx0 set idx0 + 1
endm

;PUSH ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	swi	#3
	mov	r10,	psw
	add	er8,	#-2
	if idx0 >= 8 && idx0 < 12
		st	r10,	_PSW
		l	er10,	VXR8 + idx0 - 8
		st	er10,	[er8]
		l	r10,	_PSW
	else
		st	ern,	[er8]
	endif
	st	er8,	VSP
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

;PUSH XRn
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	swi	#3
	if idx0 == 8
		mov	r10,	psw
		st	r10,	_PSW
		add	er8,	#-2
		l	er10,	VER10
		st	er10,	[er8]
		add	er8,	#-2
		l	er10,	VER8
		st	er10,	[er8]
		l	r10,	_PSW
		mov	psw,	r10
	else
		mov	er10,	sp
		mov	sp,	er8
		push	xrn
		mov	er8,	sp
		mov	sp,	er10
	endif
	st	er8,	VSP
	fetch
	idx0 set idx0 + 4
endm

;PUSH QR0
_push_qr0:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	push	qr0
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch

;PUSH QR8
_push_qr8:
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	mov	er10,	sp
	mov	sp,	er8
	push	xr12
	l	er8,	VER10
	push	er8
	l	er8,	VER8
	push	er8
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	l	r10,	_PSW
	mov	psw,	r10
	fetch

;POP Rn
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r10, r10, r10, r10, r12, r13, r14, r15>
	swi	#3
	mov	r11,	psw
	l	rn,	[er8]
	if idx0 >= 8 && idx0 < 12
		st	r10,	VXR8 + idx0 - 8
	endif
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r11
	fetch
	idx0 set idx0 + 1
endm

;POP ERn
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	swi	#3
	if idx0 >= 8 && idx0 < 12
		mov	er10,	sp
		mov	sp,	er8
		pop	er8
		st	er8,	VXR8 + idx0 - 8
		mov	er8,	sp
		mov	sp,	er10
		st	er8,	VSP
	else
		mov	r10,	psw
		l	ern,	[er8]
		add	er8,	#2
		st	er8,	VSP
		mov	psw,	r10
	endif
	fetch
	idx0 set idx0 + 2
endm

;POP XRn
idx0 set 0
irp xrn, <xr0, xr4, xr8, xr12>
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	if idx0 == 8
		pop	er8
		st	er8,	VER8
		pop	er8
		st	er8,	VER10
	else
		pop	xrn
	endif
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch
	idx0 set idx0 + 4
endm

;POP QR0
_pop_qr0:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	pop	qr0
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch

;POP QR8
_pop_qr8:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	pop	er8
	st	er8,	VER8
	pop	er8
	st	er8,	VER10
	pop	xr12
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch
