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
;Allow user programs to register interrupt handlers. Emulate VECSR, VEPSW and VECPUSTAT (including physical ECSR:ELR, XR8, SP, VSSR, psw backup _PSW and VMFLAGS) in internal ram.

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

;Flags indicating state of the virtual machine
;bit0: running
;bit1: NMI blocking
VMFLAGS	EQU	0900Fh

;Interrupt backup registers
VECSR1	EQU	09030h
VECSR2	EQU	09040h
VECSR3	EQU	09050h

VESSR1	EQU 09032h
VESSR2	EQU 09042h
VESSR3	EQU 09052h

VPELR1	EQU	09034h
VPELR2	EQU	09044h
VPELR3	EQU	09054h

VPECSR1	EQU	09036h
VPECSR2	EQU	09046h
VPECSR3	EQU	09056h

VEPSW1	EQU	09037h
VEPSW2	EQU	09047h
VEPSW3	EQU	09057h

VEPSWBAK1	EQU	09038h
VEPSWBAK2	EQU	09048h
VEPSWBAK3	EQU	09058h

VEVMFLAGS1	EQU	09039h
VEVMFLAGS2	EQU	09049h
VEVMFLAGS3	EQU	09059h

VESP1	EQU	0903Ah
VESP2	EQU	0904Ah
VESP3	EQU	0905Ah

VEXR81	EQU	0903Ch
VEXR82	EQU	0904Ch
VEXR83	EQU	0905Ch

;register backup for interrupt handlers
TMP	EQU	09060h

;stack mamory reserved for external storage access
LOCAL_STACK	EQU	09100h

;Interrupt vector table
INT_VTABLE	EQU	09100h

;Bit table indicating if custom ISR is registered for a certain interrupt
ISR_REGTABLE	EQU	09200h

;user-registered exception handler
;exception handlers should return a boolean value, true if exception handled successfully, false to forward to default handler
_EXCEPTION_HANDLER	EQU	09070h
_EXCEPTION_HANDLER_CSR	EQU	09072h
_USE_CUSTOM_EXCEPTION_HANDLER	EQU	09073h	;boolean value

extrn code	:	reload_code_segment
extrn code	:	reload_data_segment
extrn code	:	reload_stack_segment
extrn code	:	vmem_byte_store
extrn code	:	vmem_word_store
extrn code	:	vmem_byte_load
extrn code	:	vmem_word_load

extrn number	:	EXCEPTION_STACK_OVERFLOW
extrn number	:	EXCEPTION_STACK_UNDERFLOW

__EnterIntBlkSection macro
	di
	sb	VMFLAGS.1
endm

__EnterNMIBlkSection macro
	sb	VMFLAGS.1
endm

__LeaveNMIBlkSection macro
	local leave
	rb	VMFLAGS.1
	bne	leave
	sb	QWDT
leave:
endm

;helper function to call a pointer in stack
__stack_call:
	pop	pc

;BP/FP addressing instructions are implemented here in case handler segment grows too large
__vstack_load_store$overflow:
	add	sp,	#-2
	pop	er0
	mov	er0,	er0
	bps	__vstack_load_store$_underflow
	l	er0,	SS_END
	sub	r0,	r10
	subc	r1,	r11
__vstack_load_store$loop1:
	add	er2,	#-1
	add	er8,	er0
	cmp	er8,	er10
	blt	__vstack_load_store$loop1
	l	er0,	VSSR
	cmp	er2,	er0
	rt

__vstack_load_store$_underflow:
	l	er10,	SS_END
	l	er0,	SS_START
	sub	r0,	r10
	subc	r1,	r11
__vstack_load_store$loop2:
	add	er2,	#1
	add	er8,	er0
	bcy	__vstack_load_store$loop2
	bal	__vstack_load_store$loop3

__vstack_load_store$underflow:
	l	er0,	SS_START
	sub	r0,	r10
	subc	r1,	r11
__vstack_load_store$loop3:
	add	er2,	#1
	add	er8,	er0
	cmp	er8,	er10
	bge	__vstack_load_store$loop3
	l	er0,	VSSR
	cmp	er2,	er0
	rt

__vstack_byte_load_external:
	mov	er0,	er8
	mov	er10,	sp
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	lr
	bl	vmem_byte_load
	mov	r8,	r0
	pop	lr
	mov	sp,	er10
	l	er0,	TMP
	l	er2,	TMP + 2
	rt

__vstack_word_load_external:
	mov	er0,	er8
	mov	er10,	sp
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	push	lr
	bl	vmem_word_load
	mov	er8,	er0
	pop	lr
	mov	sp,	er10
	rt

__vstack_byte_store_external:
	mov	er0,	er8
	mov	er10,	sp
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	l	r8,	TMP + 4
	push	r8
	bl	vmem_byte_store
	mov	sp,	er10
	l	er0,	TMP
	l	er2,	TMP + 2
	__LeaveNMIBlkSection
	l	r10,	_PSW
	mov	psw,	r10
	b	_nop

__vstack_word_store_external:
	mov	er0,	er8
	mov	er10,	sp
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	sp,	er8
	l	er8,	TMP + 4
	push	er8
	bl	vmem_word_store
	mov	sp,	er10
	l	er0,	TMP
	l	er2,	TMP + 2
	__LeaveNMIBlkSection
	l	r10,	_PSW
	mov	psw,	r10
	b	_nop

vstack_do_load_store macro isload, regn, regn_idx
	if isload
		l	r10,	_PSW
		mov	psw,	r10
		l	regn,	[er8]
		if regn_idx >= 8 && regn_idx < 12
			st	regn,	VXR8 + regn_idx - 8
		endif
	else
		if regn_idx >= 8 && regn_idx < 12
			l	regn,	VXR8 + regn_idx - 8
			st	regn,	[er8]
		else
			st	regn,	[er8]
		endif
		l	r10,	_PSW
		mov	psw,	r10
	endif
	b	_nop
endm

vstack_load_store macro isload, regsize, regn, regn_idx, regm, regm_idx
	local overflow, underflow, _external, external
	mov	r10,	psw
	st	r10,	_PSW
	if !((regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2)
		__EnterIntBlkSection
		st	er0,	TMP
	endif
	pop	er8
	add	er8,	regm
	l	er10,	SS_START
	cmp	er8,	er10
	blt	overflow
	l	er10,	SS_END
	cmp	er8,	er10
	bge	underflow
	if !((regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2)
		l	er0,	VSSR
		l	er10,	VSREGS + regm_idx
		cmp	er0,	er10
	else
		l	regn,	VSSR
		l	er10,	VSREGS + regm_idx
		cmp	regn,	er10
	endif
	bne	_external
	if !((regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2)
		l	er0,	TMP
		__LeaveNMIBlkSection
	endif
	vstack_do_load_store isload, regn, regn_idx

overflow:
	if (regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2
		__EnterIntBlkSection
		if regn_idx != 0
			st	er0,	TMP
		endif
	endif
	if !(regn_idx == 2 && isload && regsize == 2)
		st	er2,	TMP + 2
	endif
	l	er2,	VSREGS + regm_idx
	bl	__vstack_load_store$overflow
	bne	external
	if !(regn_idx == 0 && isload && regsize == 2)
		l	er0,	TMP
	endif
	if !(regn_idx == 2 && isload && regsize == 2)
		l	er2,	TMP + 2
	endif
	__LeaveNMIBlkSection
	vstack_do_load_store isload, regn, regn_idx

underflow:
	if (regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2
		__EnterIntBlkSection
		if regn_idx != 0
			st	er0,	TMP
		endif
	endif
	if !(regn_idx == 2 && isload && regsize == 2)
		st	er2,	TMP + 2
	endif
	l	er2,	VSREGS + regm_idx
	bl	__vstack_load_store$underflow
	bne	external
	if !(regn_idx == 0 && isload && regsize == 2)
		l	er0,	TMP
	endif
	if !(regn_idx == 2 && isload && regsize == 2)
		l	er2,	TMP + 2
	endif
	__LeaveNMIBlkSection
	vstack_do_load_store isload, regn, regn_idx

_external:
	if (regn_idx < 8 || regn_idx >= 12) && isload && regsize == 2
		__EnterIntBlkSection
		if regn_idx != 0
			st	er0,	TMP
		endif
	endif
	if !(regn_idx == 2 && isload && regsize == 2)
		st	er2,	TMP + 2
	endif
	mov	er2,	er10
external:
	if isload
		if regsize == 1
			bl	__vstack_byte_load_external
		else
			bl	__vstack_word_load_external
			if regn_idx != 0
				l	er0,	TMP
			endif
			if regn_idx != 2
				l	er2,	TMP + 2
			endif
		endif
		__LeaveNMIBlkSection
		l	r10,	_PSW
		mov	psw,	r10
		if regsize == 1
			mov	regn,	r8
		else
			mov	regn,	er8
		endif
		if regn_idx >= 8 && regn_idx < 12
			st	regn,	VXR8 + regn_idx - 8
		endif
		b	_nop
	else
		if regn_idx >= 8 && regn_idx < 12
			l	regn,	VXR8 + regn_idx - 8
			st	regn,	TMP + 4
		elseif regn_idx >= 0 && regn_idx < 4
			l	regn,	TMP + regn_idx
			st	regn,	TMP + 4
		else
			st	regn,	TMP + 4
		endif
		if regsize == 1
			b	__vstack_byte_store_external
		else
			b	__vstack_word_store_external
		endif
	endif
endm

;helper function for `L Rn, Disp16[BP]` instructions
__vstack_load_r0_bp:
	vstack_load_store 1, 1, r0, 0, bp, 12
__vstack_load_r1_bp:
	vstack_load_store 1, 1, r1, 1, bp, 12
__vstack_load_r2_bp:
	vstack_load_store 1, 1, r2, 2, bp, 12
__vstack_load_r3_bp:
	vstack_load_store 1, 1, r3, 3, bp, 12
__vstack_load_r4_bp:
	vstack_load_store 1, 1, r4, 4, bp, 12
__vstack_load_r5_bp:
	vstack_load_store 1, 1, r5, 5, bp, 12
__vstack_load_r6_bp:
	vstack_load_store 1, 1, r6, 6, bp, 12
__vstack_load_r7_bp:
	vstack_load_store 1, 1, r7, 7, bp, 12
__vstack_load_r8_bp:
	vstack_load_store 1, 1, r8, 8, bp, 12
__vstack_load_r9_bp:
	vstack_load_store 1, 1, r8, 9, bp, 12
__vstack_load_r10_bp:
	vstack_load_store 1, 1, r8, 10, bp, 12
__vstack_load_r11_bp:
	vstack_load_store 1, 1, r8, 11, bp, 12
__vstack_load_r12_bp:
	vstack_load_store 1, 1, r12, 12, bp, 12
__vstack_load_r13_bp:
	vstack_load_store 1, 1, r13, 13, bp, 12
__vstack_load_r14_bp:
	vstack_load_store 1, 1, r14, 14, bp, 12
__vstack_load_r15_bp:
	vstack_load_store 1, 1, r15, 15, bp, 12

;helper function for `L Rn, Disp16[FP]` instructions
__vstack_load_r0_fp:
	vstack_load_store 1, 1, r0, 0, fp, 14
__vstack_load_r1_fp:
	vstack_load_store 1, 1, r1, 1, fp, 14
__vstack_load_r2_fp:
	vstack_load_store 1, 1, r2, 2, fp, 14
__vstack_load_r3_fp:
	vstack_load_store 1, 1, r3, 3, fp, 14
__vstack_load_r4_fp:
	vstack_load_store 1, 1, r4, 4, fp, 14
__vstack_load_r5_fp:
	vstack_load_store 1, 1, r5, 5, fp, 14
__vstack_load_r6_fp:
	vstack_load_store 1, 1, r6, 6, fp, 14
__vstack_load_r7_fp:
	vstack_load_store 1, 1, r7, 7, fp, 14
__vstack_load_r8_fp:
	vstack_load_store 1, 1, r8, 8, fp, 14
__vstack_load_r9_fp:
	vstack_load_store 1, 1, r8, 9, fp, 14
__vstack_load_r10_fp:
	vstack_load_store 1, 1, r8, 10, fp, 14
__vstack_load_r11_fp:
	vstack_load_store 1, 1, r8, 11, fp, 14
__vstack_load_r12_fp:
	vstack_load_store 1, 1, r12, 12, fp, 14
__vstack_load_r13_fp:
	vstack_load_store 1, 1, r13, 13, fp, 14
__vstack_load_r14_fp:
	vstack_load_store 1, 1, r14, 14, fp, 14
__vstack_load_r15_fp:
	vstack_load_store 1, 1, r15, 15, fp, 14

;helper function for `L ERn, Disp16[BP]` instructions
__vstack_load_er0_bp:
	vstack_load_store 1, 2, er0, 0, bp, 12
__vstack_load_er2_bp:
	vstack_load_store 1, 2, er2, 2, bp, 12
__vstack_load_er4_bp:
	vstack_load_store 1, 2, er4, 4, bp, 12
__vstack_load_er6_bp:
	vstack_load_store 1, 2, er6, 6, bp, 12
__vstack_load_er8_bp:
	vstack_load_store 1, 2, er8, 8, bp, 12
__vstack_load_er10_bp:
	vstack_load_store 1, 2, er8, 10, bp, 12
__vstack_load_er12_bp:
	vstack_load_store 1, 2, er12, 12, bp, 12
__vstack_load_er14_bp:
	vstack_load_store 1, 2, er14, 14, bp, 12

;helper function for `L ERn, Disp16[FP]` instructions
__vstack_load_er0_fp:
	vstack_load_store 1, 2, er0, 0, fp, 14
__vstack_load_er2_fp:
	vstack_load_store 1, 2, er2, 2, fp, 14
__vstack_load_er4_fp:
	vstack_load_store 1, 2, er4, 4, fp, 14
__vstack_load_er6_fp:
	vstack_load_store 1, 2, er6, 6, fp, 14
__vstack_load_er8_fp:
	vstack_load_store 1, 2, er8, 8, fp, 14
__vstack_load_er10_fp:
	vstack_load_store 1, 2, er8, 10, fp, 14
__vstack_load_er12_fp:
	vstack_load_store 1, 2, er12, 12, fp, 14
__vstack_load_er14_fp:
	vstack_load_store 1, 2, er14, 14, fp, 14

;helper function for `ST Rn, Disp16[BP]` instructions
__vstack_store_r0_bp:
	vstack_load_store 0, 1, r0, 0, bp, 12
__vstack_store_r1_bp:
	vstack_load_store 0, 1, r1, 1, bp, 12
__vstack_store_r2_bp:
	vstack_load_store 0, 1, r2, 2, bp, 12
__vstack_store_r3_bp:
	vstack_load_store 0, 1, r3, 3, bp, 12
__vstack_store_r4_bp:
	vstack_load_store 0, 1, r4, 4, bp, 12
__vstack_store_r5_bp:
	vstack_load_store 0, 1, r5, 5, bp, 12
__vstack_store_r6_bp:
	vstack_load_store 0, 1, r6, 6, bp, 12
__vstack_store_r7_bp:
	vstack_load_store 0, 1, r7, 7, bp, 12
__vstack_store_r8_bp:
	vstack_load_store 0, 1, r10, 8, bp, 12
__vstack_store_r9_bp:
	vstack_load_store 0, 1, r10, 9, bp, 12
__vstack_store_r10_bp:
	vstack_load_store 0, 1, r10, 10, bp, 12
__vstack_store_r11_bp:
	vstack_load_store 0, 1, r10, 11, bp, 12
__vstack_store_r12_bp:
	vstack_load_store 0, 1, r12, 12, bp, 12
__vstack_store_r13_bp:
	vstack_load_store 0, 1, r13, 13, bp, 12
__vstack_store_r14_bp:
	vstack_load_store 0, 1, r14, 14, bp, 12
__vstack_store_r15_bp:
	vstack_load_store 0, 1, r15, 15, bp, 12

;helper function for `ST Rn, Disp16[FP]` instructions
__vstack_store_r0_fp:
	vstack_load_store 0, 1, r0, 0, fp, 14
__vstack_store_r1_fp:
	vstack_load_store 0, 1, r1, 1, fp, 14
__vstack_store_r2_fp:
	vstack_load_store 0, 1, r2, 2, fp, 14
__vstack_store_r3_fp:
	vstack_load_store 0, 1, r3, 3, fp, 14
__vstack_store_r4_fp:
	vstack_load_store 0, 1, r4, 4, fp, 14
__vstack_store_r5_fp:
	vstack_load_store 0, 1, r5, 5, fp, 14
__vstack_store_r6_fp:
	vstack_load_store 0, 1, r6, 6, fp, 14
__vstack_store_r7_fp:
	vstack_load_store 0, 1, r7, 7, fp, 14
__vstack_store_r8_fp:
	vstack_load_store 0, 1, r10, 8, fp, 14
__vstack_store_r9_fp:
	vstack_load_store 0, 1, r10, 9, fp, 14
__vstack_store_r10_fp:
	vstack_load_store 0, 1, r10, 10, fp, 14
__vstack_store_r11_fp:
	vstack_load_store 0, 1, r10, 11, fp, 14
__vstack_store_r12_fp:
	vstack_load_store 0, 1, r12, 12, fp, 14
__vstack_store_r13_fp:
	vstack_load_store 0, 1, r13, 13, fp, 14
__vstack_store_r14_fp:
	vstack_load_store 0, 1, r14, 14, fp, 14
__vstack_store_r15_fp:
	vstack_load_store 0, 1, r15, 15, fp, 14

;helper function for `ST ERn, Disp16[BP]` instructions
__vstack_store_er0_bp:
	vstack_load_store 0, 2, er0, 0, bp, 12
__vstack_store_er2_bp:
	vstack_load_store 0, 2, er2, 2, bp, 12
__vstack_store_er4_bp:
	vstack_load_store 0, 2, er4, 4, bp, 12
__vstack_store_er6_bp:
	vstack_load_store 0, 2, er6, 6, bp, 12
__vstack_store_er8_bp:
	vstack_load_store 0, 2, er10, 8, bp, 12
__vstack_store_er10_bp:
	vstack_load_store 0, 2, er10, 10, bp, 12
__vstack_store_er12_bp:
	vstack_load_store 0, 2, er12, 12, bp, 12
__vstack_store_er14_bp:
	vstack_load_store 0, 2, er14, 14, bp, 12

;helper function for `ST ERn, Disp16[FP]` instructions
__vstack_store_er0_fp:
	vstack_load_store 0, 2, er0, 0, fp, 14
__vstack_store_er2_fp:
	vstack_load_store 0, 2, er2, 2, fp, 14
__vstack_store_er4_fp:
	vstack_load_store 0, 2, er4, 4, fp, 14
__vstack_store_er6_fp:
	vstack_load_store 0, 2, er6, 6, fp, 14
__vstack_store_er8_fp:
	vstack_load_store 0, 2, er10, 8, fp, 14
__vstack_store_er10_fp:
	vstack_load_store 0, 2, er10, 10, fp, 14
__vstack_store_er12_fp:
	vstack_load_store 0, 2, er12, 12, fp, 14
__vstack_store_er14_fp:
	vstack_load_store 0, 2, er14, 14, fp, 14

;helper function for `ADD SP, #imm16` instruction
__vstack_vsp_addition:
	mov	r10,	psw
	st	r10,	_PSW
	pop	er8
	rb	r8.0
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
	b	_nop

vsp_add_overflow:
	__EnterIntBlkSection
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
	__LeaveNMIBlkSection
	l	r10,	_PSW
	mov	psw,	r10
	b	_nop

_vsp_add_underflow:
	l	er10,	SS_END
	l	er0,	SS_START
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vsp_add_loop2:
	add	er2,	#1
	add	er8,	er0
	bcy	vsp_add_loop2
	bal	vsp_add_loop3

vsp_add_underflow:
	__EnterIntBlkSection
	st	er0,	TMP
	st	er2,	TMP + 2
	l	er0,	SS_START
	l	er2,	VSP + 2
	sub	r0,	r10
	subc	r1,	r11
vsp_add_loop3:
	add	er2,	#1
	add	er8,	er0
	cmp	er8,	er10
	bge	vsp_add_loop3
	st	er8,	VSP
	st	er2,	VSP + 2
	l	er0,	TMP
	l	er2,	TMP + 2
	__LeaveNMIBlkSection
	l	r10,	_PSW
	mov	psw,	r10
	b	_nop

;PADD/PSUB instruction handler
_padd_psub_helper macro symbol0, symbol1, symbol2, isadd, ern, regidx
	if regidx < 8 || regidx >= 12
		st	r8,	_PSW
	endif
	__EnterIntBlkSection
	if regidx == 0
		st	er2,	TMP
		if isadd
			l	er2,	symbol0
		else
			l	er2,	symbol1
		endif
		sub	r2,	r10
		subc	r3,	r11
	else
		st	er0,	TMP
		if isadd
			l	er0,	symbol0
		else
			l	er0,	symbol1
		endif
		sub	r0,	r10
		subc	r1,	r11
	endif
	if regidx >= 8 && regidx < 12
		st	er2,	TMP + 2
		l	er2,	VSREGS + regidx
	else
		l	er8,	VSREGS + regidx
	endif
symbol2:
	if regidx >= 8 && regidx < 12
		if isadd
			add	er2,	#1
		else
			add	er2,	#-1
		endif
	else
		if isadd
			add	er8,	#1
		else
			add	er8,	#-1
		endif
	endif
	if regidx == 0
		add	ern,	er2
	else
		add	ern,	er0
	endif
endm

pointer_arithmetic_fix macro isadd, ern, regidx
	local ss_fix
	local _do_ds_fix, do_ds_fix, ds_fix_loop1, ds_fix_loop2, ds_fix_nv
	local _do_ss_fix, do_ss_fix, ss_fix_loop1, ss_fix_loop2, ss_fix_nv
	mov	r8,	psw
	and	r8,	#01001111b
	if regidx >= 8 && regidx < 12
		st	r8,	_PSW
		l	er8,	VXR8 + regidx - 8
	endif
	tb	(VSREGS + regidx + 1).7
	bne	ss_fix
	if isadd
		l	er10,	DS_END
		bcy	_do_ds_fix
	else
		l	er10,	DS_START
		bnc	_do_ds_fix
	endif
	cmp	ern,	er10
	if isadd
		bge	do_ds_fix
	else
		blt	do_ds_fix
	endif
	if regidx >= 8 && regidx < 12
		l	r8,	_PSW
	endif
	mov	psw,	r8
	b	_nop

ss_fix:
	if isadd
		l	er10,	SS_END
		bcy	_do_ss_fix
	else
		l	er10,	SS_START
		bnc	_do_ss_fix
	endif
	cmp	ern,	er10
	if isadd
		bge	do_ss_fix
	else
		blt	do_ss_fix
	endif
	if regidx >= 8 && regidx < 12
		l	r8,	_PSW
	endif
	sb	r8.5
	mov	psw,	r8
	b	_nop

_do_ds_fix:
	_padd_psub_helper DS_START, DS_END, ds_fix_loop1, isadd, ern, regidx
	if isadd
		bcy	ds_fix_loop1
	else
		bnc	ds_fix_loop1
	endif
	bal	ds_fix_loop2

do_ds_fix:
	_padd_psub_helper DS_START, DS_END, ds_fix_loop2, isadd, ern, regidx
	cmp	ern,	er10
	if isadd
		bge	ds_fix_loop2
	else
		blt	ds_fix_loop2
	endif
	l	r10,	_PSW
	sb	r10.7
	if regidx >= 8 && regidx < 12
		rb	r3.7
		st	er2,	VSREGS + regidx
		st	er8,	VXR8 + regidx - 8
	else
		rb	r9.7
		st	er8,	VSREGS + regidx
	endif
	beq	ds_fix_nv
	sb	r10.4
ds_fix_nv:
	if regidx == 0
		l	er2,	TMP
	else
		l	er0,	TMP
	endif
	if regidx >= 8 && regidx < 12
		l	er2,	TMP + 2
	endif
	__LeaveNMIBlkSection
	mov	psw,	r10
	b	_nop

_do_ss_fix:
	_padd_psub_helper SS_START, SS_END, ss_fix_loop1, isadd, ern, regidx
	if isadd
		bcy	ss_fix_loop1
	else
		bnc	ss_fix_loop1
	endif
	bal	ss_fix_loop2

do_ss_fix:
	_padd_psub_helper SS_START, SS_END, ss_fix_loop2, isadd, ern, regidx
	cmp	ern,	er10
	if isadd
		bge	ss_fix_loop2
	else
		blt	ss_fix_loop2
	endif
	l	r10,	_PSW
	or	r10,	#10100000b
	if regidx >= 8 && regidx < 12
		sb	r3.7
		st	er2,	VSREGS + regidx
		st	er8,	VXR8 + regidx - 8
	else
		sb	r9.7
		st	er8,	VSREGS + regidx
	endif
	bne	ss_fix_nv
	sb	r10.4
ss_fix_nv:
	if regidx == 0
		l	er2,	TMP
	else
		l	er0,	TMP
	endif
	if regidx >= 8 && regidx < 12
		l	er2,	TMP + 2
	endif
	__LeaveNMIBlkSection
	mov	psw,	r10
	b	_nop
endm

__longptr_fix_padd_ser0:
	pointer_arithmetic_fix 1, er0, 0

__longptr_fix_padd_ser2:
	pointer_arithmetic_fix 1, er2, 2

__longptr_fix_padd_ser4:
	pointer_arithmetic_fix 1, er4, 4

__longptr_fix_padd_ser6:
	pointer_arithmetic_fix 1, er6, 6

__longptr_fix_padd_ser8:
	pointer_arithmetic_fix 1, er8, 8

__longptr_fix_padd_ser10:
	pointer_arithmetic_fix 1, er8, 10

__longptr_fix_padd_ser12:
	pointer_arithmetic_fix 1, er12, 12

__longptr_fix_padd_ser14:
	pointer_arithmetic_fix 1, er14, 14

__longptr_fix_psub_ser0:
	pointer_arithmetic_fix 0, er0, 0

__longptr_fix_psub_ser2:
	pointer_arithmetic_fix 0, er2, 2

__longptr_fix_psub_ser4:
	pointer_arithmetic_fix 0, er4, 4

__longptr_fix_psub_ser6:
	pointer_arithmetic_fix 0, er6, 6

__longptr_fix_psub_ser8:
	pointer_arithmetic_fix 0, er8, 8

__longptr_fix_psub_ser10:
	pointer_arithmetic_fix 0, er8, 10

__longptr_fix_psub_ser12:
	pointer_arithmetic_fix 0, er12, 12

__longptr_fix_psub_ser14:
	pointer_arithmetic_fix 0, er14, 14

;helper function for switching code segment on RTI/POP ECPUSTAT
;in: er8-target code segment
__rti_do_csr_switch:
	st	er8,	VCSR
	mov	r8,	#byte1 LOCAL_STACK
	mov	r9,	#byte2 LOCAL_STACK
	mov	er10,	sp
	mov	sp,	er8
	push	lr,ea
	push	xr0
	l	er0,	VCSR
	bl	reload_code_segment
	pop	xr0
	pop	ea,lr
	mov	sp,	er10
	rt

;Interrupt handlers

__int_save_cpustat macro ELEVEL
	st	er8,	VEXR81 + (ELEVEL - 1) * 10h
	st	er10,	VEXR81 + (ELEVEL - 1) * 10h + 2
	if ELEVEL < 3
		mov	er8,	elr
		mov	r10,	ecsr
		mov	r11,	epsw
		st	er8,	VPELR1 + (ELEVEL - 1) * 10h
		st	er10,	VPECSR1 + (ELEVEL - 1) * 10h
	endif
	mov	er8,	sp
	l	er10,	_PSW
	st	er8,	VESP1 + (ELEVEL - 1) * 10h
	st	er10,	VEPSWBAK1 + (ELEVEL - 1) * 10h
	l	er8,	VCSR
	l	er10,	VSSR
	st	er8,	VECSR1 + (ELEVEL - 1) * 10h
	st	er10,	VESSR1 + (ELEVEL - 1) * 10h
endm

;BRK handler
_BRK:
	tb	VMFLAGS.0
	beq	brk_default_handler
	__int_save_cpustat 2
	tb	ISR_REGTABLE.0
	beq	brk_default_handler_vm
	mov	r8,	#byte1 INT_VTABLE
	mov	r9,	#byte2 INT_VTABLE
	mov	sp,	er8
	b	_nop

brk_default_handler:
brk_default_handler_vm:

;NMICE handler
_NMICE:
	__int_save_cpustat 3
	tb	ISR_REGTABLE.1
	beq	nmice_default_handler
	mov	r8,	#byte1 (INT_VTABLE + 6)
	mov	r9,	#byte2 (INT_VTABLE + 6)
	mov	sp,	er8
	b	_nop

;Dynamically link to debugger if registered
nmice_default_handler:

;NMI handler
_NMI:
	tb	VMFLAGS.0
	beq	nmi_default_handler
	rb	VMFLAGS.1
	beq	handle_nmi
	rti

handle_nmi:
	__int_save_cpustat 2
	tb	ISR_REGTABLE.2
	beq	nmi_default_handler_vm
	mov	r8,	#byte1 (INT_VTABLE + 0Ch)
	mov	r9,	#byte2 (INT_VTABLE + 0Ch)
	mov	sp,	er8
	b	_nop

nmi_default_handler_vm:
	mov	r8,	#5Ah
wdt_clear_retry_vm:
	st	r8,	WDTCON
	tb	WDP
	beq	wdt_clear_retry_vm
	mov	r8,	#0A5h
	st	r8,	WDTCON
	l	er8,	VEXR82
	l	er10,	VEXR82 + 2
	rti
	
nmi_default_handler:
	push	r0
	mov	r0,	#5Ah
wdt_clear_retry:
	st	r0,	WDTCON
	tb	WDP
	beq	wdt_clear_retry
	mov	r0,	#0A5h
	st	r0,	WDTCON
	pop	r0
	rti

;Hardware MI handler
_MI macro intidx, mi_default_handler, mi_default_handler_vm
	tb	VMFLAGS.0
	beq	mi_default_handler
	__int_save_cpustat 1
	tb	(ISR_REGTABLE + intidx >> 3).(intidx & 7)
	beq	mi_default_handler_vm
	mov	r8,	#byte1 (INT_VTABLE + intidx * 6)
	mov	r9,	#byte2 (INT_VTABLE + intidx * 6)
	mov	sp,	er8
	b	_nop
endm

;User-reserved SWI handler
_SWI macro intidx
	__int_save_cpustat 1
	mov	r8,	#byte1 (INT_VTABLE + intidx * 6)
	mov	r9,	#byte2 (INT_VTABLE + intidx * 6)
	mov	sp,	er8
	b	_nop
endm

;Kernel-reserved software interrupt handlers

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
	__EnterNMIBlkSection
	st	er10,	VCSR
	;calls a function to load the target code segment from external storage to allocated region of the internal ram.
	mov	er0,	er10
	bl	reload_code_segment
	pop	xr0
	pop	ea
	mov	sp,	er8
	__LeaveNMIBlkSection
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
	__EnterNMIBlkSection
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
	__LeaveNMIBlkSection
	rti

do_ssr_switch:
	__EnterNMIBlkSection
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
	__LeaveNMIBlkSection
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
	__EnterNMIBlkSection
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
	__LeaveNMIBlkSection
	rti

ss_underflow:
	__EnterNMIBlkSection
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
				elseif (idx0 & 0Eh) == (idx1 & 0Eh)
					l	er8,	VXR8 + (idx0 & 0Eh) - 8
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
				elseif (idx0 & 0Eh) == (idx1 & 0Eh)
					l	er8,	VXR8 + (idx0 & 0Eh) - 8
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

;NOP
_nop:
	fetch

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

;PADD/PSUB SERn
;fix overflow in 32-bit pointer arithmetic
;Usage:
;ADD ERn, obj
;PADD/PSUB SERn
;Flags:
;C: This bit goes to 1 if an overflow took place in the previous instruction and a fix is applied, and to 0 otherwise.
;S: This bit goes to 1 if the target register represents a stack segment address and to 0 otherwise.
;OV: This bit goes to 1 if the operation produces an overflow in segment register and to 0 otherwise.

;PADD SERn
b __longptr_fix_padd_ser0
b __longptr_fix_padd_ser2
b __longptr_fix_padd_ser4
b __longptr_fix_padd_ser6
b __longptr_fix_padd_ser8
b __longptr_fix_padd_ser10
b __longptr_fix_padd_ser12
b __longptr_fix_padd_ser14

;PSUB SERn
b __longptr_fix_psub_ser0
b __longptr_fix_psub_ser2
b __longptr_fix_psub_ser4
b __longptr_fix_psub_ser6
b __longptr_fix_psub_ser8
b __longptr_fix_psub_ser10
b __longptr_fix_psub_ser12
b __longptr_fix_psub_ser14

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

;ADD SERn, #imm16
idx0 set 0
rept 8
	l	er8,	VSREGS + idx0
	pop	er10
	add	er8,	er10
	st	er8,	VSREGS + idx0
	fetch
	idx0 set idx0 + 2
endm

;ADD SP, #imm16
b __vstack_vsp_addition

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

;MOV SERn, #imm16
idx0 set 0
rept 8
	pop	er8
	st	er8,	VSREGS + idx0
	mov	er8,	er8
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

;MOV ERn, ERm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	idx1 set 0
	irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
		if idx0 >= 8 && idx0 < 12
			if idx0 == idx1
				l	er8,	VXR8 + idx0 - 8
			elseif idx1 >= 8 && idx1 < 12
				l	er8,	VXR8 + idx1 - 8
				st	er8,	VXR8 + idx0 - 8
			else
				mov	erm,	erm
				st	erm,	VXR8 + idx0 - 8
			endif
		elseif idx1 >= 8 && idx1 < 12
			l	ern,	VXR8 + idx1 - 8
		else
			mov	ern,	erm
		endif
		fetch
		idx1 set idx1 + 2
	endm
	idx0 set idx0 + 2
endm

;MOV SERn, SERm
idx0 set 0
rept 8
	idx1 set 0
	rept 8
		if idx0 == idx1
			l	er8,	VSREGS + idx0
		else
			l	er8,	VSREGS + idx1
			st	er8,	VSREGS + idx0
		endif
		fetch
		idx1 set idx1 + 2
	endm
	idx0 set idx0 + 2
endm

;MOV Rn, Rm
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
	idx1 set 0
	irp rm, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
		if idx0 >= 8 && idx0 < 12
			if idx0 == idx1
				l	r8,	VXR8 + idx0 - 8
			elseif idx1 >= 8 && idx1 < 12
				l	r8,	VXR8 + idx1 - 8
				st	r8,	VXR8 + idx0 - 8
			else
				mov	rm,	rm
				st	rm,	VXR8 + idx0 - 8
			endif
		elseif idx1 >= 8 && idx1 < 12
			l	rn,	VXR8 + idx1 - 8
		else
			mov	rn,	rm
		endif
		fetch
		idx1 set idx1 + 1
	endm
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
		rb	r8.0
		st	er8,	VSP
	else
		st	ern,	VSP
		rb	VSP.0
	endif
	l	er8,	VSREGS + idx0
	st	er8,	VSP + 2
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

;MOV ERn, SERm
idx0 set 0
irp ern, <er0, er2, er4, er6, er8, er10, er12, er14>
	irp vserm, <0, 2, 4, 6, 8, 10, 12, 14>
		if idx0 >= 8 && idx0 < 12
			l	er8,	VSREGS + vserm
			st	er8,	VXR8 + idx0 - 8
		else
			l	ern,	VSREGS + vserm
		endif
		fetch
	endm
	idx0 set idx0 + 2
endm

;MOV SERn, ERm
idx1 set 0
irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
	irp vsern, <0, 2, 4, 6, 8, 10, 12, 14>
		if idx1 >= 8 && idx1 < 12
			l	er8,	VXR8 + idx1 - 8
			st	er8,	VSREGS + vsern
		else
			mov	erm,	erm
			st	erm,	VSREGS + vsern
		endif
		fetch
	endm
	idx1 set idx1 + 2
endm

;MOV Rn, PSW
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
	mov	rn,	psw
	if idx0 >= 8 && idx0 < 12
		st	rn,	VXR8 + idx0 - 8
	endif
	fetch
	idx0 set idx0 + 1
endm

;MOV PSW, Rm
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r8, r8, r8, r12, r13, r14, r15>
	if idx0 >= 8 && idx0 < 12
		l	rn,	VXR8 + idx0 - 8
	endif
	mov	psw,	rn
	fetch
	idx0 set idx0 + 1
endm

;MOV PSW, #imm8
_mov_psw_imm8:
	pop	psw
	fetch

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
b	__vstack_store_r0_bp
b	__vstack_store_r1_bp
b	__vstack_store_r2_bp
b	__vstack_store_r3_bp
b	__vstack_store_r4_bp
b	__vstack_store_r5_bp
b	__vstack_store_r6_bp
b	__vstack_store_r7_bp
b	__vstack_store_r8_bp
b	__vstack_store_r9_bp
b	__vstack_store_r10_bp
b	__vstack_store_r11_bp
b	__vstack_store_r12_bp
b	__vstack_store_r13_bp
b	__vstack_store_r14_bp
b	__vstack_store_r15_bp

;ST Rn, Disp16[FP]
b	__vstack_store_r0_fp
b	__vstack_store_r1_fp
b	__vstack_store_r2_fp
b	__vstack_store_r3_fp
b	__vstack_store_r4_fp
b	__vstack_store_r5_fp
b	__vstack_store_r6_fp
b	__vstack_store_r7_fp
b	__vstack_store_r8_fp
b	__vstack_store_r9_fp
b	__vstack_store_r10_fp
b	__vstack_store_r11_fp
b	__vstack_store_r12_fp
b	__vstack_store_r13_fp
b	__vstack_store_r14_fp
b	__vstack_store_r15_fp

;ST ERn, Disp16[BP]
b	__vstack_store_er0_bp
b	__vstack_store_er2_bp
b	__vstack_store_er4_bp
b	__vstack_store_er6_bp
b	__vstack_store_er8_bp
b	__vstack_store_er10_bp
b	__vstack_store_er12_bp
b	__vstack_store_er14_bp

;ST ERn, Disp16[FP]
b	__vstack_store_er0_fp
b	__vstack_store_er2_fp
b	__vstack_store_er4_fp
b	__vstack_store_er6_fp
b	__vstack_store_er8_fp
b	__vstack_store_er10_fp
b	__vstack_store_er12_fp
b	__vstack_store_er14_fp

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
b	__vstack_load_r0_bp
b	__vstack_load_r1_bp
b	__vstack_load_r2_bp
b	__vstack_load_r3_bp
b	__vstack_load_r4_bp
b	__vstack_load_r5_bp
b	__vstack_load_r6_bp
b	__vstack_load_r7_bp
b	__vstack_load_r8_bp
b	__vstack_load_r9_bp
b	__vstack_load_r10_bp
b	__vstack_load_r11_bp
b	__vstack_load_r12_bp
b	__vstack_load_r13_bp
b	__vstack_load_r14_bp
b	__vstack_load_r15_bp

;L Rn, Disp16[FP]
b	__vstack_load_r0_fp
b	__vstack_load_r1_fp
b	__vstack_load_r2_fp
b	__vstack_load_r3_fp
b	__vstack_load_r4_fp
b	__vstack_load_r5_fp
b	__vstack_load_r6_fp
b	__vstack_load_r7_fp
b	__vstack_load_r8_fp
b	__vstack_load_r9_fp
b	__vstack_load_r10_fp
b	__vstack_load_r11_fp
b	__vstack_load_r12_fp
b	__vstack_load_r13_fp
b	__vstack_load_r14_fp
b	__vstack_load_r15_fp

;L ERn, Disp16[BP]
b	__vstack_load_er0_bp
b	__vstack_load_er2_bp
b	__vstack_load_er4_bp
b	__vstack_load_er6_bp
b	__vstack_load_er8_bp
b	__vstack_load_er10_bp
b	__vstack_load_er12_bp
b	__vstack_load_er14_bp

;L ERn, Disp16[FP]
b	__vstack_load_er0_fp
b	__vstack_load_er2_fp
b	__vstack_load_er4_fp
b	__vstack_load_er6_fp
b	__vstack_load_er8_fp
b	__vstack_load_er10_fp
b	__vstack_load_er12_fp
b	__vstack_load_er14_fp

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

;RTI
_rti:
	mov	r10,	psw
	and	r10,	#3
	beq	_rt
	mov	r8,	#byte1 (VECSR1 - 10h)
	mov	r9,	#byte2 (VECSR1 - 10h)
	sll	r10,	#4
	mov	r11,	#0
	add	er8,	er10
rti_restore_cpustat:
	mov	psw,	#1
	mov	sp,	er8
	pop	er8
	l	er10,	VCSR
	cmp	er8,	er10
	beq	rti_skip_csr_switch
	__EnterNMIBlkSection
	bl	__rti_do_csr_switch
	__LeaveNMIBlkSection
rti_skip_csr_switch:
	pop	er8
	swi	#2
	pop	xr8
	mov	elr,	er8
	mov	ecsr,	r9
	mov	epsw,	r10
	pop	xr8
	st	er8,	_PSW
	mov	er8,	sp
	mov	sp,	er10
	l	er10,	02h[er8]
	l	er8,	[er8]
	rti

;RTICE
_rtice:
	mov	r8,	#byte1 VECSR3
	mov	r9,	#byte2 VECSR3
	bal	rti_restore_cpustat

;SYSCALL Cadr
;calls native function in the ROM
_syscall:
	mov	r8,	psw
	st	r8,	_PSW
	__EnterNMIBlkSection
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
	di
	bl	__stack_call
	st	er8,	VER8
	st	er10,	VER10
	mov	r10,	psw
	__LeaveNMIBlkSection
	mov	r8,	#byte1 VLR
	mov	r9,	#byte2 VLR
	tb	_PSW.3
	bne	_syscall_retn_ei
	mov	psw,	r10
	swi	#1
	fetch

_syscall_retn_ei:
	mov	psw,	r10
	swi	#1
	ei
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

;VDSR/VSSR <- SERn
idx0 set 0
rept 8
	mov	r10,	psw
	l	er8,	VSREGS + idx0
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

;PUSH ECPUSTAT
_push_ecpustat:
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	add	er8,	#-10h
	st	er8,	VSP
	and	r10,	#3
	beq	push_ecpustat_noexcept_fallback
	mov	r11,	#0
	
	l	r10,	_PSW
	mov	psw,	r10
	fetch

push_ecpustat_noexcept_fallback:

;PUSH LR
_push_lr:
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	add	er8,	#-4
	st	er8,	VSP
	l	er10,	VLR
	st	er10,	[er8]
	add	er8,	#2
	l	er10,	VLCSR
	st	er10,	[er8]
	l	r10,	_PSW
	mov	psw,	r10
	fetch

;PUSH EA
_push_ea:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	add	sp,	#-2
	mov	er8,	sp
	st	er8,	VSP
	add	sp,	#2
	push	ea
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
	st	er8,	VSP
	st	rn,	[er8]
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
	st	er8,	VSP
	if idx0 >= 8 && idx0 < 12
		st	r10,	_PSW
		l	er10,	VXR8 + idx0 - 8
		st	er10,	[er8]
		l	r10,	_PSW
	else
		st	ern,	[er8]
	endif
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
		add	er8,	#-4
		st	er8,	VSP
		l	er10,	VER8
		st	er10,	[er8]
		add	er8,	#2
		l	er10,	VER10
		st	er10,	[er8]
		l	r10,	_PSW
		mov	psw,	r10
	else
		mov	er10,	sp
		mov	sp,	er8
		add	sp,	#-4
		mov	er8,	sp
		st	er8,	VSP
		add	sp,	#4
		push	xrn
		mov	sp,	er10
	endif
	fetch
	idx0 set idx0 + 4
endm

;PUSH QR0
_push_qr0:
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	add	sp,	#-8
	mov	er8,	sp
	st	er8,	VSP
	add	sp,	#8
	push	qr0
	mov	sp,	er10
	fetch

;PUSH QR8
_push_qr8:
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	mov	er10,	sp
	mov	sp,	er8
	add	er8,	#-8
	st	er8,	VSP
	push	xr12
	l	er8,	VER10
	push	er8
	l	er8,	VER8
	push	er8
	mov	sp,	er10
	l	r10,	_PSW
	mov	psw,	r10
	fetch

;PUSH SERn
idx0 set 0
rept 8
	swi	#3
	mov	r10,	psw
	st	r10,	_PSW
	add	er8,	#-2
	st	er8,	VSP
	l	er10,	VSREGS + idx0
	st	er10,	[er8]
	l	r10,	_PSW
	mov	psw,	r10
	fetch
	idx0 set idx0 + 2
endm

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

;POP SERn
idx0 set 0
rept 8
	swi	#3
	mov	er10,	sp
	mov	sp,	er8
	pop	er8
	st	er8,	VSREGS + idx0
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch
	idx0 set idx0 + 2
endm

;SWI #snum
idx0 set 4
rept 60
	swi	#idx0
	fetch
	idx0 set idx0 + 1
endm

;ICESWI
_ICESWI:
	mov	r11,	psw
	mov	r8,	#byte1 offset iceswi_retn
	mov	r9,	#byte2 offset iceswi_retn
	mov	r10,	#seg iceswi_retn
	st	er8,	VPELR3
	st	er10,	VPECSR3
	iceswi
iceswi_retn:
	fetch
