type(ML620909)
model	large

;U16 Virtual Machine for running external code
;General design:
;Virtual Instruction Pointer: SP	Working Register: XR8 (generally xr8 is less accessed than xr12 since they are used for stack addressing, or xr0 since they are used for passing arguments.)
;using 16-bit code segment register and data segment register (for virtual memory accessing)
;emulate VCSR, VDSR, VLCSR, VLR, VXR8 and VSP in internal ram
;separate internal ram into code segment, virtual memory segment, local ram segment and stack segment.
;use 32-bit virtual ram pointer, where low 16 bits represents the physical address in the virtual memory segment of the internal ram. Virtual memory access should be prefixed to identify data segment. Local ram accessing should not be prefixed since segment switching is handled in prefix.
;use 32-bit instruction pointer, where low 16 bits point to the physical address in the code segment of the internal ram. Conditional branch and register calls only allows jumping to the same segment. Use long jump to switch segment.
;use SWI0 to handle exceptions. SWI1 for switching code segment, SWI2 for switching data segment.
;implement malloc and free to handle virtual memory allocating. malloc should return a 32-bit pointer pointing to the virtual memory. Do not use malloc for accessing reserved local ram.
;When doing data transfer between data segments, use local ram as buffer. Do not directly transfer between different segments since memory access to a different data segment will reload the whole virtual memory segment from external storage.
;it's recommended to cache frequently accessed data in local ram segment.

;virtual registers
VLR	EQU	09000h
VLCSR	EQU	09002h
VCSR	EQU	09004h
VDSR	EQU	09006h
VSP	EQU	09008h
VXR8	EQU	0900Ah
VER8	EQU	0900Ah
VER10	EQU	0900Ch

;PSW backup
_PSW	EQU	0900Eh

;A flag to identify if the cpu is running in virtualized mode
VM_RUNNING	EQU	0900Fh

;register backup for interrupt handlers
TMP	EQU	09010h

;user-registered exception handler
;exception handlers should return a boolean value, true if exception handled successfully, false to forward to default handler
_EXCEPTION_HANDLER	EQU	09020h
_EXCEPTION_HANDLER_CSR	EQU	09022h
_USE_CUSTOM_EXCEPTION_HANDLER	EQU	09023h	;boolean value

extrn code	:	reload_code_segment
extrn code	:	reload_data_segment

;helper function to call a pointer in stack
__stack_call:
	pop	pc

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
	l	er10,	VSP
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
;Change current data segment
;in: er8-target data segment
_SWI_2:
	l	er10,	VDSR
	cmp	er8,	er10
	bne	do_dsr_switch
	rti

do_dsr_switch:
	st	er8,	VDSR
	mov	er8,	sp
	st	er8,	TMP
	l	er8,	VSP
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
	mov	r8,	psw
	st	r8,	_PSW
	pop	er10
	l	er8,	VSP
	add	er8,	er10
	st	er8,	VSP
	l	r8,	_PSW
	mov	psw,	r8
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
; idx1 set 0
; irp erm, <er0, er2, er4, er6, er8, er10, er12, er14>
; 	idx0 set 0
; 	irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15>
; 		if idx1 >= 8 && idx1 < 12
; 			st	er8,	TMP
; 			mov	r11,	psw
; 			l	er8,	VXR8 + idx1 - 8
; 			if idx0 == idx1
; 				st	r8,	[er8]
; 			elseif idx0 == idx1 - 1
; 				st	r9,	[er8]
; 			else
; 				l	r10,	VXR8 + idx0 - 8
; 				st	r10,	[er8]
; 			endif
; 			l	er8,	TMP
; 			mov	psw,	r11
; 		elseif idx0 >= 8 && idx0 < 12
; 			mov	r11,	psw
; 			l	r10,	VXR8 + idx0 - 8
; 			mov	psw,	r11
; 			st	r10,	[erm]
; 		else
; 			st	rn,	[erm]
; 		endif
; 		fetch
; 		idx0 set idx0 + 1
; 	endm
; 	idx1 set idx1 + 2
; endm

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
	

;long jump
_b:
	mov	er8,	sp
	swi	#1
	fetch

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

_rt:
	mov	r10,	psw
	mov	r8,	#byte1 VLR
	mov	r9,	#byte2 VLR
	mov	psw,	r10
	swi	#1
	fetch

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

;VDSR <- ERn
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

;VDSR <- imm16
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
	mov	r8,	psw
	st	r8,	_PSW
	l	er8,	VSP
	add	er8,	#-2
	l	er10,	VLCSR
	st	er10,	[er8]
	add	er8,	#-2
	l	er10,	VLR
	st	er10,	[er8]
	st	er8,	VSP
	l	r8,	_PSW
	mov	psw,	r8
	fetch

;PUSH EA
_push_ea:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
	mov	er10,	sp
	mov	sp,	er8
	push	ea
	mov	er8,	sp
	st	er8,	VSP
	mov	sp,	er10
	fetch

;POP EA
_pop_ea:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
	mov	er10,	sp
	mov	sp,	er8
	pop	ea
	mov	er8,	sp
	st	er8,	VSP
	mov	sp,	er10
	fetch

;POP PSW
_pop_psw:
	l	er8,	VSP
	l	r10,	[er8]
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r10
	fetch

;POP LR
_pop_lr:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
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
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
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
	mov	r11,	psw
	l	er8,	VSP
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
	mov	r10,	psw
	l	er8,	VSP
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

;PUSH XR0
_push_xr0:
	mov	r10,	psw
	l	er8,	VSP
	add	er8,	#-2
	st	er2,	[er8]
	add	er8,	#-2
	st	er0,	[er8]
	st	er8,	VSP
	mov	psw,	r10
	fetch

;PUSH XR4
_push_xr4:
	mov	r10,	psw
	l	er8,	VSP
	add	er8,	#-2
	st	er6,	[er8]
	add	er8,	#-2
	st	er4,	[er8]
	st	er8,	VSP
	mov	psw,	r10
	fetch

;PUSH XR8
_push_xr8:
	mov	r10,	psw
	st	r10,	_PSW
	l	er8,	VSP
	add	er8,	#-2
	l	er10,	VER10
	st	er10,	[er8]
	add	er8,	#-2
	l	er10,	VER8
	st	er10,	[er8]
	st	er8,	VSP
	l	r10,	_PSW
	mov	psw,	r10
	fetch

;PUSH XR12
_push_xr12:
	mov	r10,	psw
	l	er8,	VSP
	add	er8,	#-2
	st	er14,	[er8]
	add	er8,	#-2
	st	er12,	[er8]
	st	er8,	VSP
	mov	psw,	r10
	fetch

;PUSH QR0
_push_qr0:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
	mov	er10,	sp
	mov	sp,	er8
	push	qr0
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch

;PUSH QR8
_push_qr8:
	mov	r8,	psw
	st	r8,	_PSW
	l	er8,	VSP
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
	l	r8,	_PSW
	mov	psw,	r8
	fetch

;POP Rn
idx0 set 0
irp rn, <r0, r1, r2, r3, r4, r5, r6, r7, r10, r10, r10, r10, r12, r13, r14, r15>
	mov	r11,	psw
	l	er8,	VSP
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
	if idx0 >= 8 && idx0 < 12
		mov	r10,	psw
		l	er8,	VSP
		mov	psw,	r10
		mov	er10,	sp
		mov	sp,	er8
		pop	er8
		st	er8,	VXR8 + idx0 - 8
		mov	er8,	sp
		mov	sp,	er10
		st	er8,	VSP
	else
		mov	r10,	psw
		l	er8,	VSP
		l	ern,	[er8]
		add	er8,	#2
		st	er8,	VSP
		mov	psw,	r10
	endif
	fetch
	idx0 set idx0 + 2
endm

;POP XR0
_pop_xr0:
	mov	r10,	psw
	l	er8,	VSP
	l	er0,	[er8]
	add	er8,	#2
	l	er2,	[er8]
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r10
	fetch

;POP XR4
_pop_xr4:
	mov	r10,	psw
	l	er8,	VSP
	l	er4,	[er8]
	add	er8,	#2
	l	er6,	[er8]
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r10
	fetch

;POP XR8
_pop_xr8:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
	mov	er10,	sp
	mov	sp,	er8
	pop	er8
	st	er8,	VER8
	pop	er8
	st	er8,	VER10
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch

;POP XR12
_pop_xr12:
	mov	r10,	psw
	l	er8,	VSP
	l	er12,	[er8]
	add	er8,	#2
	l	er14,	[er8]
	add	er8,	#2
	st	er8,	VSP
	mov	psw,	r10
	fetch

;POP QR0
_pop_qr0:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
	mov	er10,	sp
	mov	sp,	er8
	pop	qr0
	mov	er8,	sp
	mov	sp,	er10
	st	er8,	VSP
	fetch

;POP QR8
_pop_qr8:
	mov	r10,	psw
	l	er8,	VSP
	mov	psw,	r10
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
