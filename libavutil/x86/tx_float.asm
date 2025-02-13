;******************************************************************************
;* Copyright (c) Lynne
;*
;* This file is part of FFmpeg.
;*
;* FFmpeg is free software; you can redistribute it and/or
;* modify it under the terms of the GNU Lesser General Public
;* License as published by the Free Software Foundation; either
;* version 2.1 of the License, or (at your option) any later version.
;*
;* FFmpeg is distributed in the hope that it will be useful,
;* but WITHOUT ANY WARRANTY; without even the implied warranty of
;* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;* Lesser General Public License for more details.
;*
;* You should have received a copy of the GNU Lesser General Public
;* License along with FFmpeg; if not, write to the Free Software
;* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;******************************************************************************

; Open `doc/transforms.md` to see the code upon which the transforms here were
; based upon and compare.

; TODO:
;       carry over registers from smaller transforms to save on ~8 loads/stores
;       check if vinsertf could be faster than verpm2f128 for duplication
;       even faster FFT8 (current one is very #instructions optimized)
;       replace some xors with blends + addsubs?
;       replace some shuffles with vblends?
;       avx512 split-radix

%include "libavutil/x86/x86util.asm"

%define private_prefix ff_tx

%if ARCH_X86_64
%define ptr resq
%else
%define ptr resd
%endif

%assign i 16
%rep 14
cextern tab_ %+ i %+ _float ; ff_tab_i_float...
%assign i (i << 1)
%endrep

struc AVTXContext
    .len:          resd 1 ; Length
    .inv           resd 1 ; Inverse flag
    .map:           ptr 1 ; Lookup table(s)
    .exp:           ptr 1 ; Exponentiation factors
    .tmp:           ptr 1 ; Temporary data

    .sub:           ptr 1 ; Subcontexts
    .fn:            ptr 4 ; Subcontext functions
    .nb_sub:       resd 1 ; Subcontext count

    ; Everything else is inaccessible
endstruc

SECTION_RODATA 32

%define POS 0x00000000
%define NEG 0x80000000

%define M_SQRT1_2 0.707106781186547524401
%define COS16_1   0.92387950420379638671875
%define COS16_3   0.3826834261417388916015625

d8_mult_odd:   dd M_SQRT1_2, -M_SQRT1_2, -M_SQRT1_2, M_SQRT1_2, \
                  M_SQRT1_2, -M_SQRT1_2, -M_SQRT1_2, M_SQRT1_2

s8_mult_odd:   dd 1.0, 1.0, -1.0, 1.0, -M_SQRT1_2, -M_SQRT1_2, M_SQRT1_2, M_SQRT1_2
s8_perm_even:  dd 1, 3, 0, 2, 1, 3, 2, 0
s8_perm_odd1:  dd 3, 3, 1, 1, 1, 1, 3, 3
s8_perm_odd2:  dd 1, 2, 0, 3, 1, 0, 0, 1

s16_mult_even: dd 1.0, 1.0, M_SQRT1_2, M_SQRT1_2, 1.0, -1.0, M_SQRT1_2, -M_SQRT1_2
s16_mult_odd1: dd COS16_1,  COS16_1,  COS16_3,  COS16_3,  COS16_1, -COS16_1,  COS16_3, -COS16_3
s16_mult_odd2: dd COS16_3, -COS16_3,  COS16_1, -COS16_1, -COS16_3, -COS16_3, -COS16_1, -COS16_1
s16_perm:      dd 0, 1, 2, 3, 1, 0, 3, 2

mask_mmmmpppm: dd NEG, NEG, NEG, NEG, POS, POS, POS, NEG
mask_ppmpmmpm: dd POS, POS, NEG, POS, NEG, NEG, POS, NEG
mask_mppmmpmp: dd NEG, POS, POS, NEG, NEG, POS, NEG, POS
mask_mpmppmpm: dd NEG, POS, NEG, POS, POS, NEG, POS, NEG
mask_pmmppmmp: dd POS, NEG, NEG, POS, POS, NEG, NEG, POS
mask_pmpmpmpm: times 4 dd POS, NEG

SECTION .text

; Load complex values (64 bits) via a lookup table
; %1 - output register
; %2 - GRP of base input memory address
; %3 - GPR of LUT (int32_t indices) address
; %4 - LUT offset
; %5 - temporary GPR (only used if vgather is not used)
; %6 - temporary register (for avx only)
%macro LOAD64_LUT 5-6
    mov      %5d, [%3 + %4 + 0]
    movsd  xmm%1, [%2 + %5q*8]
%if mmsize == 32
    mov      %5d, [%3 + %4 + 8]
    movsd  xmm%6, [%2 + %5q*8]
%endif
    mov      %5d, [%3 + %4 + 4]
    movhps xmm%1, [%2 + %5q*8]
%if mmsize == 32
    mov      %5d, [%3 + %4 + 12]
    movhps xmm%6, [%2 + %5q*8]
    vinsertf128 %1, %1, xmm%6, 1
%endif
%endmacro

; Single 2-point in-place complex FFT (will do 2 transforms at once in AVX mode)
; %1 - coefficients (r0.reim, r1.reim)
; %2 - temporary
%macro FFT2 2
    shufps   %2, %1, %1, q3322
    shufps   %1, %1, %1, q1100

    addsubps %1, %1, %2

    shufps   %1, %1, %1, q2031
%endmacro

; Single 4-point in-place complex FFT (will do 2 transforms at once in [AVX] mode)
; %1 - even coefficients (r0.reim, r2.reim, r4.reim, r6.reim)
; %2 - odd coefficients  (r1.reim, r3.reim, r5.reim, r7.reim)
; %3 - temporary
%macro FFT4 3
    subps  %3, %1, %2         ;  r1234, [r5678]
    addps  %1, %1, %2         ;  t1234, [t5678]

    shufps %2, %1, %3, q1010  ;  t12, r12
    shufps %1, %1, %3, q2332  ;  t34, r43

    subps  %3, %2, %1         ;  a34, b32
    addps  %2, %2, %1         ;  a12, b14

    shufps %1, %2, %3, q1010  ;  a1234     even

    shufps %2, %2, %3, q2332  ;  b1423
    shufps %2, %2, %2, q1320  ;  b1234     odd
%endmacro

; Single/Dual 8-point in-place complex FFT (will do 2 transforms in [AVX] mode)
; %1 - even coefficients (a0.reim, a2.reim, [b0.reim, b2.reim])
; %2 - even coefficients (a4.reim, a6.reim, [b4.reim, b6.reim])
; %3 - odd coefficients  (a1.reim, a3.reim, [b1.reim, b3.reim])
; %4 - odd coefficients  (a5.reim, a7.reim, [b5.reim, b7.reim])
; %5 - temporary
; %6 - temporary
%macro FFT8 6
    addps    %5, %1, %3               ; q1-8
    addps    %6, %2, %4               ; k1-8

    subps    %1, %1, %3               ; r1-8
    subps    %2, %2, %4               ; j1-8

    shufps   %4, %1, %1, q2323        ; r4343
    shufps   %3, %5, %6, q3032        ; q34, k14

    shufps   %1, %1, %1, q1010        ; r1212
    shufps   %5, %5, %6, q1210        ; q12, k32

    xorps    %4, %4, [mask_pmmppmmp]  ; r4343 * pmmp
    addps    %6, %5, %3               ; s12, g12

    mulps    %2, %2, [d8_mult_odd]    ; r8 * d8_mult_odd
    subps    %5, %5, %3               ; s34, g43

    addps    %3, %1, %4               ; z1234
    unpcklpd %1, %6, %5               ; s1234

    shufps   %4, %2, %2, q2301        ; j2143
    shufps   %6, %6, %5, q2332        ; g1234

    addsubps %2, %2, %4               ; l2143
    shufps   %5, %2, %2, q0123        ; l3412
    addsubps %5, %5, %2               ; t1234

    subps    %2, %1, %6               ; h1234 even
    subps    %4, %3, %5               ; u1234 odd

    addps    %1, %1, %6               ; w1234 even
    addps    %3, %3, %5               ; o1234 odd
%endmacro

; Single 8-point in-place complex FFT in 20 instructions
; %1 - even coefficients (r0.reim, r2.reim, r4.reim, r6.reim)
; %2 - odd coefficients  (r1.reim, r3.reim, r5.reim, r7.reim)
; %3 - temporary
; %4 - temporary
%macro FFT8_AVX 4
    subps      %3, %1, %2               ;  r1234, r5678
    addps      %1, %1, %2               ;  q1234, q5678

    vpermilps  %2, %3, [s8_perm_odd1]   ;  r4422, r6688
    shufps     %4, %1, %1, q3322        ;  q1122, q5566

    movsldup   %3, %3                   ;  r1133, r5577
    shufps     %1, %1, %1, q1100        ;  q3344, q7788

    addsubps   %3, %3, %2               ;  z1234, z5678
    addsubps   %1, %1, %4               ;  s3142, s7586

    mulps      %3, %3, [s8_mult_odd]    ;  z * s8_mult_odd
    vpermilps  %1, %1, [s8_perm_even]   ;  s1234, s5687 !

    shufps     %2, %3, %3, q2332        ;   junk, z7887
    xorps      %4, %1, [mask_mmmmpppm]  ;  e1234, e5687 !

    vpermilps  %3, %3, [s8_perm_odd2]   ;  z2314, z6556
    vperm2f128 %1, %1, %4, 0x03         ;  e5687, s1234

    addsubps   %2, %2, %3               ;   junk, t5678
    subps      %1, %1, %4               ;  w1234, w5678 even

    vperm2f128 %2, %2, %2, 0x11         ;  t5678, t5678
    vperm2f128 %3, %3, %3, 0x00         ;  z2314, z2314

    xorps      %2, %2, [mask_ppmpmmpm]  ;  t * ppmpmmpm
    addps      %2, %3, %2               ;  u1234, u5678 odd
%endmacro

; Single 16-point in-place complex FFT
; %1 - even coefficients (r0.reim, r2.reim,  r4.reim,  r6.reim)
; %2 - even coefficients (r8.reim, r10.reim, r12.reim, r14.reim)
; %3 - odd coefficients  (r1.reim, r3.reim,  r5.reim,  r7.reim)
; %4 - odd coefficients  (r9.reim, r11.reim, r13.reim, r15.reim)
; %5, %6 - temporary
; %7, %8 - temporary (optional)
%macro FFT16 6-8
    FFT4       %3, %4, %5
%if %0 > 7
    FFT8_AVX   %1, %2, %6, %7
    movaps     %8, [mask_mpmppmpm]
    movaps     %7, [s16_perm]
%define mask %8
%define perm %7
%elif %0 > 6
    FFT8_AVX   %1, %2, %6, %7
    movaps     %7, [s16_perm]
%define mask [mask_mpmppmpm]
%define perm %7
%else
    FFT8_AVX   %1, %2, %6, %5
%define mask [mask_mpmppmpm]
%define perm [s16_perm]
%endif
    xorps      %5, %5, %5                   ; 0

    shufps     %6, %4, %4, q2301            ; z12.imre, z13.imre...
    shufps     %5, %5, %3, q2301            ; 0, 0, z8.imre...

    mulps      %4, %4, [s16_mult_odd1]      ; z.reim * costab
    xorps      %5, %5, [mask_mppmmpmp]
%if cpuflag(fma3)
    fmaddps    %6, %6, [s16_mult_odd2], %4  ; s[8..15]
    addps      %5, %3, %5                   ; s[0...7]
%else
    mulps      %6, %6, [s16_mult_odd2]      ; z.imre * costab

    addps      %5, %3, %5                   ; s[0...7]
    addps      %6, %4, %6                   ; s[8..15]
%endif
    mulps      %5, %5, [s16_mult_even]      ; s[0...7]*costab

    xorps      %4, %6, mask                 ; s[8..15]*mpmppmpm
    xorps      %3, %5, mask                 ; s[0...7]*mpmppmpm

    vperm2f128 %4, %4, %4, 0x01             ; s[12..15, 8..11]
    vperm2f128 %3, %3, %3, 0x01             ; s[4..7, 0..3]

    addps      %6, %6, %4                   ; y56, u56, y34, u34
    addps      %5, %5, %3                   ; w56, x56, w34, x34

    vpermilps  %6, %6, perm                 ; y56, u56, y43, u43
    vpermilps  %5, %5, perm                 ; w56, x56, w43, x43

    subps      %4, %2, %6                   ; odd  part 2
    addps      %3, %2, %6                   ; odd  part 1

    subps      %2, %1, %5                   ; even part 2
    addps      %1, %1, %5                   ; even part 1
%undef mask
%undef perm
%endmacro

; Cobmines m0...m8 (tx1[even, even, odd, odd], tx2,3[even], tx2,3[odd]) coeffs
; Uses all 16 of registers.
; Output is slightly permuted such that tx2,3's coefficients are interleaved
; on a 2-point basis (look at `doc/transforms.md`)
%macro SPLIT_RADIX_COMBINE 17
%if %1 && mmsize == 32
    vperm2f128 %14, %6, %7, 0x20     ; m2[0], m2[1], m3[0], m3[1] even
    vperm2f128 %16, %9, %8, 0x20     ; m2[0], m2[1], m3[0], m3[1] odd
    vperm2f128 %15, %6, %7, 0x31     ; m2[2], m2[3], m3[2], m3[3] even
    vperm2f128 %17, %9, %8, 0x31     ; m2[2], m2[3], m3[2], m3[3] odd
%endif

    shufps     %12, %10, %10, q2200  ; cos00224466
    shufps     %13, %11, %11, q1133  ; wim77553311
    movshdup   %10, %10              ; cos11335577
    shufps     %11, %11, %11, q0022  ; wim66442200

%if %1 && mmsize == 32
    shufps     %6, %14, %14, q2301   ; m2[0].imre, m2[1].imre, m2[2].imre, m2[3].imre even
    shufps     %8, %16, %16, q2301   ; m2[0].imre, m2[1].imre, m2[2].imre, m2[3].imre odd
    shufps     %7, %15, %15, q2301   ; m3[0].imre, m3[1].imre, m3[2].imre, m3[3].imre even
    shufps     %9, %17, %17, q2301   ; m3[0].imre, m3[1].imre, m3[2].imre, m3[3].imre odd

    mulps      %14, %14, %13         ; m2[0123]reim * wim7531 even
    mulps      %16, %16, %11         ; m2[0123]reim * wim7531 odd
    mulps      %15, %15, %13         ; m3[0123]reim * wim7531 even
    mulps      %17, %17, %11         ; m3[0123]reim * wim7531 odd
%else
    mulps      %14, %6, %13          ; m2,3[01]reim * wim7531 even
    mulps      %16, %8, %11          ; m2,3[01]reim * wim7531 odd
    mulps      %15, %7, %13          ; m2,3[23]reim * wim7531 even
    mulps      %17, %9, %11          ; m2,3[23]reim * wim7531 odd
    ; reorder the multiplies to save movs reg, reg in the %if above
    shufps     %6, %6, %6, q2301     ; m2[0].imre, m2[1].imre, m3[0].imre, m3[1].imre even
    shufps     %8, %8, %8, q2301     ; m2[0].imre, m2[1].imre, m3[0].imre, m3[1].imre odd
    shufps     %7, %7, %7, q2301     ; m2[2].imre, m2[3].imre, m3[2].imre, m3[3].imre even
    shufps     %9, %9, %9, q2301     ; m2[2].imre, m2[3].imre, m3[2].imre, m3[3].imre odd
%endif

%if cpuflag(fma3) ; 11 - 5 = 6 instructions saved through FMA!
    fmaddsubps %6, %6, %12, %14      ; w[0..8] even
    fmaddsubps %8, %8, %10, %16      ; w[0..8] odd
    fmsubaddps %7, %7, %12, %15      ; j[0..8] even
    fmsubaddps %9, %9, %10, %17      ; j[0..8] odd
    movaps     %13, [mask_pmpmpmpm]  ; "subaddps? pfft, who needs that!"
%else
    mulps      %6, %6, %12           ; m2,3[01]imre * cos0246
    mulps      %8, %8, %10           ; m2,3[01]imre * cos0246
    movaps     %13, [mask_pmpmpmpm]  ; "subaddps? pfft, who needs that!"
    mulps      %7, %7, %12           ; m2,3[23]reim * cos0246
    mulps      %9, %9, %10           ; m2,3[23]reim * cos0246
    addsubps   %6, %6, %14           ; w[0..8]
    addsubps   %8, %8, %16           ; w[0..8]
    xorps      %15, %15, %13         ; +-m2,3[23]imre * wim7531
    xorps      %17, %17, %13         ; +-m2,3[23]imre * wim7531
    addps      %7, %7, %15           ; j[0..8]
    addps      %9, %9, %17           ; j[0..8]
%endif

    addps      %14, %6, %7           ; t10235476 even
    addps      %16, %8, %9           ; t10235476 odd
    subps      %15, %6, %7           ; +-r[0..7] even
    subps      %17, %8, %9           ; +-r[0..7] odd

    shufps     %14, %14, %14, q2301  ; t[0..7] even
    shufps     %16, %16, %16, q2301  ; t[0..7] odd
    xorps      %15, %15, %13         ; r[0..7] even
    xorps      %17, %17, %13         ; r[0..7] odd

    subps      %6, %2, %14           ; m2,3[01] even
    subps      %8, %4, %16           ; m2,3[01] odd
    subps      %7, %3, %15           ; m2,3[23] even
    subps      %9, %5, %17           ; m2,3[23] odd

    addps      %2, %2, %14           ; m0 even
    addps      %4, %4, %16           ; m0 odd
    addps      %3, %3, %15           ; m1 even
    addps      %5, %5, %17           ; m1 odd
%endmacro

; Same as above, only does one parity at a time, takes 3 temporary registers,
; however, if the twiddles aren't needed after this, the registers they use
; can be used as any of the temporary registers.
%macro SPLIT_RADIX_COMBINE_HALF 10
%if %1
    shufps     %8, %6, %6, q2200     ; cos00224466
    shufps     %9, %7, %7, q1133     ; wim77553311
%else
    shufps     %8, %6, %6, q3311     ; cos11335577
    shufps     %9, %7, %7, q0022     ; wim66442200
%endif

    mulps      %10, %4, %9           ; m2,3[01]reim * wim7531 even
    mulps      %9, %9, %5            ; m2,3[23]reim * wim7531 even

    shufps     %4, %4, %4, q2301     ; m2[0].imre, m2[1].imre, m3[0].imre, m3[1].imre even
    shufps     %5, %5, %5, q2301     ; m2[2].imre, m2[3].imre, m3[2].imre, m3[3].imre even

%if cpuflag(fma3)
    fmaddsubps %4, %4, %8, %10       ; w[0..8] even
    fmsubaddps %5, %5, %8, %9        ; j[0..8] even
    movaps     %10, [mask_pmpmpmpm]
%else
    mulps      %4, %4, %8            ; m2,3[01]imre * cos0246
    mulps      %5, %5, %8            ; m2,3[23]reim * cos0246
    addsubps   %4, %4, %10           ; w[0..8]
    movaps     %10, [mask_pmpmpmpm]
    xorps      %9, %9, %10           ; +-m2,3[23]imre * wim7531
    addps      %5, %5, %9            ; j[0..8]
%endif

    addps      %8, %4, %5            ; t10235476
    subps      %9, %4, %5            ; +-r[0..7]

    shufps     %8, %8, %8, q2301     ; t[0..7]
    xorps      %9, %9, %10           ; r[0..7]

    subps      %4, %2, %8            ; %3,3[01]
    subps      %5, %3, %9            ; %3,3[23]

    addps      %2, %2, %8            ; m0
    addps      %3, %3, %9            ; m1
%endmacro

; Same as above, tries REALLY hard to use 2 temporary registers.
%macro SPLIT_RADIX_COMBINE_LITE 9
%if %1
    shufps     %8, %6, %6, q2200        ; cos00224466
    shufps     %9, %7, %7, q1133        ; wim77553311
%else
    shufps     %8, %6, %6, q3311        ; cos11335577
    shufps     %9, %7, %7, q0022        ; wim66442200
%endif

    mulps      %9, %9, %4               ; m2,3[01]reim * wim7531 even
    shufps     %4, %4, %4, q2301        ; m2[0].imre, m2[1].imre, m3[0].imre, m3[1].imre even

%if cpuflag(fma3)
    fmaddsubps %4, %4, %8, %9           ; w[0..8] even
%else
    mulps      %4, %4, %8               ; m2,3[01]imre * cos0246
    addsubps   %4, %4, %9               ; w[0..8]
%endif

%if %1
    shufps     %9, %7, %7, q1133        ; wim77553311
%else
    shufps     %9, %7, %7, q0022        ; wim66442200
%endif

    mulps      %9, %9, %5               ; m2,3[23]reim * wim7531 even
    shufps     %5, %5, %5, q2301        ; m2[2].imre, m2[3].imre, m3[2].imre, m3[3].imre even
%if cpuflag (fma3)
    fmsubaddps %5, %5, %8, %9           ; j[0..8] even
%else
    mulps      %5, %5, %8               ; m2,3[23]reim * cos0246
    xorps      %9, %9, [mask_pmpmpmpm]  ; +-m2,3[23]imre * wim7531
    addps      %5, %5, %9               ; j[0..8]
%endif

    addps      %8, %4, %5               ; t10235476
    subps      %9, %4, %5               ; +-r[0..7]

    shufps     %8, %8, %8, q2301        ; t[0..7]
    xorps      %9, %9, [mask_pmpmpmpm]  ; r[0..7]

    subps      %4, %2, %8               ; %3,3[01]
    subps      %5, %3, %9               ; %3,3[23]

    addps      %2, %2, %8               ; m0
    addps      %3, %3, %9               ; m1
%endmacro

%macro SPLIT_RADIX_COMBINE_64 0
    SPLIT_RADIX_COMBINE_LITE 1, m0, m1, tx1_e0, tx2_e0, tw_e, tw_o, tmp1, tmp2

    movaps [outq +  0*mmsize], m0
    movaps [outq +  4*mmsize], m1
    movaps [outq +  8*mmsize], tx1_e0
    movaps [outq + 12*mmsize], tx2_e0

    SPLIT_RADIX_COMBINE_HALF 0, m2, m3, tx1_o0, tx2_o0, tw_e, tw_o, tmp1, tmp2, m0

    movaps [outq +  2*mmsize], m2
    movaps [outq +  6*mmsize], m3
    movaps [outq + 10*mmsize], tx1_o0
    movaps [outq + 14*mmsize], tx2_o0

    movaps tw_e,           [tab_64_float + mmsize]
    vperm2f128 tw_o, tw_o, [tab_64_float + 64 - 4*7 - mmsize], 0x23

    movaps m0, [outq +  1*mmsize]
    movaps m1, [outq +  3*mmsize]
    movaps m2, [outq +  5*mmsize]
    movaps m3, [outq +  7*mmsize]

    SPLIT_RADIX_COMBINE 0, m0, m2, m1, m3, tx1_e1, tx2_e1, tx1_o1, tx2_o1, tw_e, tw_o, \
                           tmp1, tmp2, tx2_o0, tx1_o0, tx2_e0, tx1_e0 ; temporary registers

    movaps [outq +  1*mmsize], m0
    movaps [outq +  3*mmsize], m1
    movaps [outq +  5*mmsize], m2
    movaps [outq +  7*mmsize], m3

    movaps [outq +  9*mmsize], tx1_e1
    movaps [outq + 11*mmsize], tx1_o1
    movaps [outq + 13*mmsize], tx2_e1
    movaps [outq + 15*mmsize], tx2_o1
%endmacro

; Perform a single even/odd split radix combination with loads and stores
; The _4 indicates this is a quarter of the iterations required to complete a full
; combine loop
; %1 must contain len*2, %2 must contain len*4, %3 must contain len*6
%macro SPLIT_RADIX_LOAD_COMBINE_4 8
    movaps m8,         [rtabq + (%5)*mmsize + %7]
    vperm2f128 m9, m9, [itabq - (%5)*mmsize + %8], 0x23

    movaps m0, [outq +      (0 + %4)*mmsize + %6]
    movaps m2, [outq +      (2 + %4)*mmsize + %6]
    movaps m1, [outq + %1 + (0 + %4)*mmsize + %6]
    movaps m3, [outq + %1 + (2 + %4)*mmsize + %6]

    movaps m4, [outq + %2 + (0 + %4)*mmsize + %6]
    movaps m6, [outq + %2 + (2 + %4)*mmsize + %6]
    movaps m5, [outq + %3 + (0 + %4)*mmsize + %6]
    movaps m7, [outq + %3 + (2 + %4)*mmsize + %6]

    SPLIT_RADIX_COMBINE 0, m0, m1, m2, m3, \
                           m4, m5, m6, m7, \
                           m8, m9, \
                           m10, m11, m12, m13, m14, m15

    movaps [outq +      (0 + %4)*mmsize + %6], m0
    movaps [outq +      (2 + %4)*mmsize + %6], m2
    movaps [outq + %1 + (0 + %4)*mmsize + %6], m1
    movaps [outq + %1 + (2 + %4)*mmsize + %6], m3

    movaps [outq + %2 + (0 + %4)*mmsize + %6], m4
    movaps [outq + %2 + (2 + %4)*mmsize + %6], m6
    movaps [outq + %3 + (0 + %4)*mmsize + %6], m5
    movaps [outq + %3 + (2 + %4)*mmsize + %6], m7
%endmacro

%macro SPLIT_RADIX_LOAD_COMBINE_FULL 2-5
%if %0 > 2
%define offset_c %3
%else
%define offset_c 0
%endif
%if %0 > 3
%define offset_r %4
%else
%define offset_r 0
%endif
%if %0 > 4
%define offset_i %5
%else
%define offset_i 0
%endif

    SPLIT_RADIX_LOAD_COMBINE_4 %1, 2*%1, %2, 0, 0, offset_c, offset_r, offset_i
    SPLIT_RADIX_LOAD_COMBINE_4 %1, 2*%1, %2, 1, 1, offset_c, offset_r, offset_i
    SPLIT_RADIX_LOAD_COMBINE_4 %1, 2*%1, %2, 4, 2, offset_c, offset_r, offset_i
    SPLIT_RADIX_LOAD_COMBINE_4 %1, 2*%1, %2, 5, 3, offset_c, offset_r, offset_i
%endmacro

; Perform a single even/odd split radix combination with loads, deinterleaves and
; stores. The _2 indicates this is a half of the iterations required to complete
; a full combine+deinterleave loop
; %3 must contain len*2, %4 must contain len*4, %5 must contain len*6
%macro SPLIT_RADIX_COMBINE_DEINTERLEAVE_2 6
    movaps m8,         [rtabq + (0 + %2)*mmsize]
    vperm2f128 m9, m9, [itabq - (0 + %2)*mmsize], 0x23

    movaps m0, [outq +      (0 + 0 + %1)*mmsize + %6]
    movaps m2, [outq +      (2 + 0 + %1)*mmsize + %6]
    movaps m1, [outq + %3 + (0 + 0 + %1)*mmsize + %6]
    movaps m3, [outq + %3 + (2 + 0 + %1)*mmsize + %6]

    movaps m4, [outq + %4 + (0 + 0 + %1)*mmsize + %6]
    movaps m6, [outq + %4 + (2 + 0 + %1)*mmsize + %6]
    movaps m5, [outq + %5 + (0 + 0 + %1)*mmsize + %6]
    movaps m7, [outq + %5 + (2 + 0 + %1)*mmsize + %6]

    SPLIT_RADIX_COMBINE 0, m0, m1, m2, m3, \
       m4, m5, m6, m7, \
       m8, m9, \
       m10, m11, m12, m13, m14, m15

    unpckhpd m10, m0, m2
    unpckhpd m11, m1, m3
    unpckhpd m12, m4, m6
    unpckhpd m13, m5, m7
    unpcklpd m0, m0, m2
    unpcklpd m1, m1, m3
    unpcklpd m4, m4, m6
    unpcklpd m5, m5, m7

    vextractf128 [outq +      (0 + 0 + %1)*mmsize + %6 +  0], m0,  0
    vextractf128 [outq +      (0 + 0 + %1)*mmsize + %6 + 16], m10, 0
    vextractf128 [outq + %3 + (0 + 0 + %1)*mmsize + %6 +  0], m1,  0
    vextractf128 [outq + %3 + (0 + 0 + %1)*mmsize + %6 + 16], m11, 0

    vextractf128 [outq + %4 + (0 + 0 + %1)*mmsize + %6 +  0], m4,  0
    vextractf128 [outq + %4 + (0 + 0 + %1)*mmsize + %6 + 16], m12, 0
    vextractf128 [outq + %5 + (0 + 0 + %1)*mmsize + %6 +  0], m5,  0
    vextractf128 [outq + %5 + (0 + 0 + %1)*mmsize + %6 + 16], m13, 0

    vperm2f128 m10, m10, m0, 0x13
    vperm2f128 m11, m11, m1, 0x13
    vperm2f128 m12, m12, m4, 0x13
    vperm2f128 m13, m13, m5, 0x13

    movaps m8,         [rtabq + (1 + %2)*mmsize]
    vperm2f128 m9, m9, [itabq - (1 + %2)*mmsize], 0x23

    movaps m0, [outq +      (0 + 1 + %1)*mmsize + %6]
    movaps m2, [outq +      (2 + 1 + %1)*mmsize + %6]
    movaps m1, [outq + %3 + (0 + 1 + %1)*mmsize + %6]
    movaps m3, [outq + %3 + (2 + 1 + %1)*mmsize + %6]

    movaps [outq +      (0 + 1 + %1)*mmsize + %6], m10 ; m0 conflict
    movaps [outq + %3 + (0 + 1 + %1)*mmsize + %6], m11 ; m1 conflict

    movaps m4, [outq + %4 + (0 + 1 + %1)*mmsize + %6]
    movaps m6, [outq + %4 + (2 + 1 + %1)*mmsize + %6]
    movaps m5, [outq + %5 + (0 + 1 + %1)*mmsize + %6]
    movaps m7, [outq + %5 + (2 + 1 + %1)*mmsize + %6]

    movaps [outq + %4 + (0 + 1 + %1)*mmsize + %6], m12 ; m4 conflict
    movaps [outq + %5 + (0 + 1 + %1)*mmsize + %6], m13 ; m5 conflict

    SPLIT_RADIX_COMBINE 0, m0, m1, m2, m3, \
                           m4, m5, m6, m7, \
                           m8, m9, \
                           m10, m11, m12, m13, m14, m15 ; temporary registers

    unpcklpd m8,  m0, m2
    unpcklpd m9,  m1, m3
    unpcklpd m10, m4, m6
    unpcklpd m11, m5, m7
    unpckhpd m0, m0, m2
    unpckhpd m1, m1, m3
    unpckhpd m4, m4, m6
    unpckhpd m5, m5, m7

    vextractf128 [outq +      (2 + 0 + %1)*mmsize + %6 +  0], m8,  0
    vextractf128 [outq +      (2 + 0 + %1)*mmsize + %6 + 16], m0,  0
    vextractf128 [outq +      (2 + 1 + %1)*mmsize + %6 +  0], m8,  1
    vextractf128 [outq +      (2 + 1 + %1)*mmsize + %6 + 16], m0,  1

    vextractf128 [outq + %3 + (2 + 0 + %1)*mmsize + %6 +  0], m9,  0
    vextractf128 [outq + %3 + (2 + 0 + %1)*mmsize + %6 + 16], m1,  0
    vextractf128 [outq + %3 + (2 + 1 + %1)*mmsize + %6 +  0], m9,  1
    vextractf128 [outq + %3 + (2 + 1 + %1)*mmsize + %6 + 16], m1,  1

    vextractf128 [outq + %4 + (2 + 0 + %1)*mmsize + %6 +  0], m10, 0
    vextractf128 [outq + %4 + (2 + 0 + %1)*mmsize + %6 + 16], m4,  0
    vextractf128 [outq + %4 + (2 + 1 + %1)*mmsize + %6 +  0], m10, 1
    vextractf128 [outq + %4 + (2 + 1 + %1)*mmsize + %6 + 16], m4,  1

    vextractf128 [outq + %5 + (2 + 0 + %1)*mmsize + %6 +  0], m11, 0
    vextractf128 [outq + %5 + (2 + 0 + %1)*mmsize + %6 + 16], m5,  0
    vextractf128 [outq + %5 + (2 + 1 + %1)*mmsize + %6 +  0], m11, 1
    vextractf128 [outq + %5 + (2 + 1 + %1)*mmsize + %6 + 16], m5,  1
%endmacro

%macro SPLIT_RADIX_COMBINE_DEINTERLEAVE_FULL 2-3
%if %0 > 2
%define offset %3
%else
%define offset 0
%endif
    SPLIT_RADIX_COMBINE_DEINTERLEAVE_2 0, 0, %1, %1*2, %2, offset
    SPLIT_RADIX_COMBINE_DEINTERLEAVE_2 4, 2, %1, %1*2, %2, offset
%endmacro

INIT_XMM sse3
cglobal fft2_float, 4, 4, 2, ctx, out, in, stride
    movaps m0, [inq]
    FFT2 m0, m1
    movaps [outq], m0
    RET

%macro FFT4 2
INIT_XMM sse2
cglobal fft4_ %+ %1 %+ _float, 4, 4, 3, ctx, out, in, stride
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]

%if %2
    shufps m2, m1, m0, q3210
    shufps m0, m0, m1, q3210
    movaps m1, m2
%endif

    FFT4 m0, m1, m2

    unpcklpd m2, m0, m1
    unpckhpd m0, m0, m1

    movaps [outq + 0*mmsize], m2
    movaps [outq + 1*mmsize], m0

    RET
%endmacro

FFT4 fwd, 0
FFT4 inv, 1

%macro FFT8_SSE_FN 2
INIT_XMM sse3
cglobal fft8_ %+ %1, 4, 4, 6, ctx, out, in, tmp
%if %2
    mov ctxq, [ctxq + AVTXContext.map]
    LOAD64_LUT m0, inq, ctxq, (mmsize/2)*0, tmpq
    LOAD64_LUT m1, inq, ctxq, (mmsize/2)*1, tmpq
    LOAD64_LUT m2, inq, ctxq, (mmsize/2)*2, tmpq
    LOAD64_LUT m3, inq, ctxq, (mmsize/2)*3, tmpq
%else
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]
    movaps m2, [inq + 2*mmsize]
    movaps m3, [inq + 3*mmsize]
%endif

    FFT8 m0, m1, m2, m3, m4, m5

    unpcklpd m4, m0, m3
    unpcklpd m5, m1, m2
    unpckhpd m0, m0, m3
    unpckhpd m1, m1, m2

    movups [outq + 0*mmsize], m4
    movups [outq + 1*mmsize], m0
    movups [outq + 2*mmsize], m5
    movups [outq + 3*mmsize], m1

    RET
%endmacro

FFT8_SSE_FN float,    1
FFT8_SSE_FN ns_float, 0

%macro FFT8_AVX_FN 2
INIT_YMM avx
cglobal fft8_ %+ %1, 4, 4, 4, ctx, out, in, tmp
%if %2
    mov ctxq, [ctxq + AVTXContext.map]
    LOAD64_LUT m0, inq, ctxq, (mmsize/2)*0, tmpq, m2
    LOAD64_LUT m1, inq, ctxq, (mmsize/2)*1, tmpq, m3
%else
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]
%endif

    FFT8_AVX m0, m1, m2, m3

    unpcklpd m2, m0, m1
    unpckhpd m0, m0, m1

    ; Around 2% faster than 2x vperm2f128 + 2x movapd
    vextractf128 [outq + 16*0], m2, 0
    vextractf128 [outq + 16*1], m0, 0
    vextractf128 [outq + 16*2], m2, 1
    vextractf128 [outq + 16*3], m0, 1

    RET
%endmacro

FFT8_AVX_FN float,    1
FFT8_AVX_FN ns_float, 0

%macro FFT16_FN 3
INIT_YMM %1
cglobal fft16_ %+ %2, 4, 4, 8, ctx, out, in, tmp
%if %3
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]
    movaps m2, [inq + 2*mmsize]
    movaps m3, [inq + 3*mmsize]
%else
    mov ctxq, [ctxq + AVTXContext.map]
    LOAD64_LUT m0, inq, ctxq, (mmsize/2)*0, tmpq, m4
    LOAD64_LUT m1, inq, ctxq, (mmsize/2)*1, tmpq, m5
    LOAD64_LUT m2, inq, ctxq, (mmsize/2)*2, tmpq, m6
    LOAD64_LUT m3, inq, ctxq, (mmsize/2)*3, tmpq, m7
%endif

    FFT16 m0, m1, m2, m3, m4, m5, m6, m7

    unpcklpd m5, m1, m3
    unpcklpd m4, m0, m2
    unpckhpd m1, m1, m3
    unpckhpd m0, m0, m2

    vextractf128 [outq + 16*0], m4, 0
    vextractf128 [outq + 16*1], m0, 0
    vextractf128 [outq + 16*2], m4, 1
    vextractf128 [outq + 16*3], m0, 1
    vextractf128 [outq + 16*4], m5, 0
    vextractf128 [outq + 16*5], m1, 0
    vextractf128 [outq + 16*6], m5, 1
    vextractf128 [outq + 16*7], m1, 1

    RET
%endmacro

FFT16_FN avx,  float,    0
FFT16_FN avx,  ns_float, 1
FFT16_FN fma3, float,    0
FFT16_FN fma3, ns_float, 1

%macro FFT32_FN 3
INIT_YMM %1
cglobal fft32_ %+ %2, 4, 4, 16, ctx, out, in, tmp
%if %3
    movaps m4, [inq + 4*mmsize]
    movaps m5, [inq + 5*mmsize]
    movaps m6, [inq + 6*mmsize]
    movaps m7, [inq + 7*mmsize]
%else
    mov ctxq, [ctxq + AVTXContext.map]
    LOAD64_LUT m4, inq, ctxq, (mmsize/2)*4, tmpq,  m8
    LOAD64_LUT m5, inq, ctxq, (mmsize/2)*5, tmpq,  m9
    LOAD64_LUT m6, inq, ctxq, (mmsize/2)*6, tmpq, m10
    LOAD64_LUT m7, inq, ctxq, (mmsize/2)*7, tmpq, m11
%endif

    FFT8 m4, m5, m6, m7, m8, m9

%if %3
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]
    movaps m2, [inq + 2*mmsize]
    movaps m3, [inq + 3*mmsize]
%else
    LOAD64_LUT m0, inq, ctxq, (mmsize/2)*0, tmpq,  m8
    LOAD64_LUT m1, inq, ctxq, (mmsize/2)*1, tmpq,  m9
    LOAD64_LUT m2, inq, ctxq, (mmsize/2)*2, tmpq, m10
    LOAD64_LUT m3, inq, ctxq, (mmsize/2)*3, tmpq, m11
%endif

    movaps m8,         [tab_32_float]
    vperm2f128 m9, m9, [tab_32_float + 4*8 - 4*7], 0x23

    FFT16 m0, m1, m2, m3, m10, m11, m12, m13

    SPLIT_RADIX_COMBINE 1, m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, \
                           m10, m11, m12, m13, m14, m15 ; temporary registers

    unpcklpd  m9, m1, m3
    unpcklpd m10, m5, m7
    unpcklpd  m8, m0, m2
    unpcklpd m11, m4, m6
    unpckhpd  m1, m1, m3
    unpckhpd  m5, m5, m7
    unpckhpd  m0, m0, m2
    unpckhpd  m4, m4, m6

    vextractf128 [outq + 16* 0],  m8, 0
    vextractf128 [outq + 16* 1],  m0, 0
    vextractf128 [outq + 16* 2],  m8, 1
    vextractf128 [outq + 16* 3],  m0, 1
    vextractf128 [outq + 16* 4],  m9, 0
    vextractf128 [outq + 16* 5],  m1, 0
    vextractf128 [outq + 16* 6],  m9, 1
    vextractf128 [outq + 16* 7],  m1, 1

    vextractf128 [outq + 16* 8], m11, 0
    vextractf128 [outq + 16* 9],  m4, 0
    vextractf128 [outq + 16*10], m11, 1
    vextractf128 [outq + 16*11],  m4, 1
    vextractf128 [outq + 16*12], m10, 0
    vextractf128 [outq + 16*13],  m5, 0
    vextractf128 [outq + 16*14], m10, 1
    vextractf128 [outq + 16*15],  m5, 1

    RET
%endmacro

%if ARCH_X86_64
FFT32_FN avx,  float,    0
FFT32_FN avx,  ns_float, 1
FFT32_FN fma3, float,    0
FFT32_FN fma3, ns_float, 1
%endif

%macro FFT_SPLIT_RADIX_DEF 1-2
ALIGN 16
.%1 %+ pt:
    PUSH lenq
    mov lenq, (%1/4)

    add outq, (%1*4) - (%1/1)
    call .32pt

    add outq, (%1*2) - (%1/2) ; the synth loops also increment outq
    call .32pt

    POP lenq
    sub outq, (%1*4) + (%1*2) + (%1/2)

    lea rtabq, [tab_ %+ %1 %+ _float]
    lea itabq, [tab_ %+ %1 %+ _float + %1 - 4*7]

%if %0 > 1
    cmp tgtq, %1
    je .deinterleave

    mov tmpq, %1

.synth_ %+ %1:
    SPLIT_RADIX_LOAD_COMBINE_FULL 2*%1, 6*%1, 0, 0, 0
    add outq, 8*mmsize
    add rtabq, 4*mmsize
    sub itabq, 4*mmsize
    sub tmpq, 4*mmsize
    jg .synth_ %+ %1

    cmp lenq, %1
    jg %2 ; can't do math here, nasm doesn't get it
    ret
%endif
%endmacro

%macro FFT_SPLIT_RADIX_FN 3
INIT_YMM %1
cglobal fft_sr_ %+ %2, 4, 8, 16, 272, lut, out, in, len, tmp, itab, rtab, tgt
    movsxd lenq, dword [lutq + AVTXContext.len]
    mov lutq, [lutq + AVTXContext.map]
    mov tgtq, lenq

; Bottom-most/32-point transform ===============================================
ALIGN 16
.32pt:
%if %3
    movaps m4, [inq + 4*mmsize]
    movaps m5, [inq + 5*mmsize]
    movaps m6, [inq + 6*mmsize]
    movaps m7, [inq + 7*mmsize]
%else
    LOAD64_LUT m4, inq, lutq, (mmsize/2)*4, tmpq,  m8
    LOAD64_LUT m5, inq, lutq, (mmsize/2)*5, tmpq,  m9
    LOAD64_LUT m6, inq, lutq, (mmsize/2)*6, tmpq, m10
    LOAD64_LUT m7, inq, lutq, (mmsize/2)*7, tmpq, m11
%endif

    FFT8 m4, m5, m6, m7, m8, m9

%if %3
    movaps m0, [inq + 0*mmsize]
    movaps m1, [inq + 1*mmsize]
    movaps m2, [inq + 2*mmsize]
    movaps m3, [inq + 3*mmsize]
%else
    LOAD64_LUT m0, inq, lutq, (mmsize/2)*0, tmpq,  m8
    LOAD64_LUT m1, inq, lutq, (mmsize/2)*1, tmpq,  m9
    LOAD64_LUT m2, inq, lutq, (mmsize/2)*2, tmpq, m10
    LOAD64_LUT m3, inq, lutq, (mmsize/2)*3, tmpq, m11
%endif

    movaps m8,         [tab_32_float]
    vperm2f128 m9, m9, [tab_32_float + 32 - 4*7], 0x23

    FFT16 m0, m1, m2, m3, m10, m11, m12, m13

    SPLIT_RADIX_COMBINE 1, m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, \
                           m10, m11, m12, m13, m14, m15 ; temporary registers

    movaps [outq + 1*mmsize], m1
    movaps [outq + 3*mmsize], m3
    movaps [outq + 5*mmsize], m5
    movaps [outq + 7*mmsize], m7

%if %3
    add inq, 8*mmsize
%else
    add lutq, (mmsize/2)*8
%endif
    cmp lenq, 32
    jg .64pt

    movaps [outq + 0*mmsize], m0
    movaps [outq + 2*mmsize], m2
    movaps [outq + 4*mmsize], m4
    movaps [outq + 6*mmsize], m6

    ret

; 64-point transform ===========================================================
ALIGN 16
.64pt:
; Helper defines, these make it easier to track what's happening
%define tx1_e0 m4
%define tx1_e1 m5
%define tx1_o0 m6
%define tx1_o1 m7
%define tx2_e0 m8
%define tx2_e1 m9
%define tx2_o0 m10
%define tx2_o1 m11
%define tw_e m12
%define tw_o m13
%define tmp1 m14
%define tmp2 m15

    SWAP m4, m1
    SWAP m6, m3

%if %3
    movaps tx1_e0, [inq + 0*mmsize]
    movaps tx1_e1, [inq + 1*mmsize]
    movaps tx1_o0, [inq + 2*mmsize]
    movaps tx1_o1, [inq + 3*mmsize]
%else
    LOAD64_LUT tx1_e0, inq, lutq, (mmsize/2)*0, tmpq, tw_e
    LOAD64_LUT tx1_e1, inq, lutq, (mmsize/2)*1, tmpq, tw_o
    LOAD64_LUT tx1_o0, inq, lutq, (mmsize/2)*2, tmpq, tmp1
    LOAD64_LUT tx1_o1, inq, lutq, (mmsize/2)*3, tmpq, tmp2
%endif

    FFT16 tx1_e0, tx1_e1, tx1_o0, tx1_o1, tw_e, tw_o, tx2_o0, tx2_o1

%if %3
    movaps tx2_e0, [inq + 4*mmsize]
    movaps tx2_e1, [inq + 5*mmsize]
    movaps tx2_o0, [inq + 6*mmsize]
    movaps tx2_o1, [inq + 7*mmsize]
%else
    LOAD64_LUT tx2_e0, inq, lutq, (mmsize/2)*4, tmpq, tmp1
    LOAD64_LUT tx2_e1, inq, lutq, (mmsize/2)*5, tmpq, tmp2
    LOAD64_LUT tx2_o0, inq, lutq, (mmsize/2)*6, tmpq, tw_o
    LOAD64_LUT tx2_o1, inq, lutq, (mmsize/2)*7, tmpq, tw_e
%endif

    FFT16 tx2_e0, tx2_e1, tx2_o0, tx2_o1, tmp1, tmp2, tw_e, tw_o

    movaps tw_e,           [tab_64_float]
    vperm2f128 tw_o, tw_o, [tab_64_float + 64 - 4*7], 0x23

%if %3
    add inq, 8*mmsize
%else
    add lutq, (mmsize/2)*8
%endif
    cmp tgtq, 64
    je .deinterleave

    SPLIT_RADIX_COMBINE_64

    cmp lenq, 64
    jg .128pt
    ret

; 128-point transform ==========================================================
ALIGN 16
.128pt:
    PUSH lenq
    mov lenq, 32

    add outq, 16*mmsize
    call .32pt

    add outq, 8*mmsize
    call .32pt

    POP lenq
    sub outq, 24*mmsize

    lea rtabq, [tab_128_float]
    lea itabq, [tab_128_float + 128 - 4*7]

    cmp tgtq, 128
    je .deinterleave

    SPLIT_RADIX_LOAD_COMBINE_FULL 2*128, 6*128

    cmp lenq, 128
    jg .256pt
    ret

; 256-point transform ==========================================================
ALIGN 16
.256pt:
    PUSH lenq
    mov lenq, 64

    add outq, 32*mmsize
    call .32pt

    add outq, 16*mmsize
    call .32pt

    POP lenq
    sub outq, 48*mmsize

    lea rtabq, [tab_256_float]
    lea itabq, [tab_256_float + 256 - 4*7]

    cmp tgtq, 256
    je .deinterleave

    SPLIT_RADIX_LOAD_COMBINE_FULL 2*256, 6*256
    SPLIT_RADIX_LOAD_COMBINE_FULL 2*256, 6*256, 8*mmsize, 4*mmsize, -4*mmsize

    cmp lenq, 256
    jg .512pt
    ret

; 512-point transform ==========================================================
ALIGN 16
.512pt:
    PUSH lenq
    mov lenq, 128

    add outq, 64*mmsize
    call .32pt

    add outq, 32*mmsize
    call .32pt

    POP lenq
    sub outq, 96*mmsize

    lea rtabq, [tab_512_float]
    lea itabq, [tab_512_float + 512 - 4*7]

    cmp tgtq, 512
    je .deinterleave

    mov tmpq, 4

.synth_512:
    SPLIT_RADIX_LOAD_COMBINE_FULL 2*512, 6*512
    add outq, 8*mmsize
    add rtabq, 4*mmsize
    sub itabq, 4*mmsize
    sub tmpq, 1
    jg .synth_512

    cmp lenq, 512
    jg .1024pt
    ret

; 1024-point transform ==========================================================
ALIGN 16
.1024pt:
    PUSH lenq
    mov lenq, 256

    add outq, 96*mmsize
    call .32pt

    add outq, 64*mmsize
    call .32pt

    POP lenq
    sub outq, 192*mmsize

    lea rtabq, [tab_1024_float]
    lea itabq, [tab_1024_float + 1024 - 4*7]

    cmp tgtq, 1024
    je .deinterleave

    mov tmpq, 8

.synth_1024:
    SPLIT_RADIX_LOAD_COMBINE_FULL 2*1024, 6*1024
    add outq, 8*mmsize
    add rtabq, 4*mmsize
    sub itabq, 4*mmsize
    sub tmpq, 1
    jg .synth_1024

    cmp lenq, 1024
    jg .2048pt
    ret

; 2048 to 131072-point transforms ==============================================
FFT_SPLIT_RADIX_DEF 2048,  .4096pt
FFT_SPLIT_RADIX_DEF 4096,  .8192pt
FFT_SPLIT_RADIX_DEF 8192,  .16384pt
FFT_SPLIT_RADIX_DEF 16384, .32768pt
FFT_SPLIT_RADIX_DEF 32768, .65536pt
FFT_SPLIT_RADIX_DEF 65536, .131072pt
FFT_SPLIT_RADIX_DEF 131072

;===============================================================================
; Final synthesis + deinterleaving code
;===============================================================================
.deinterleave:
    cmp lenq, 64
    je .64pt_deint

    imul tmpq, lenq, 2
    lea lutq, [4*lenq + tmpq]

.synth_deinterleave:
    SPLIT_RADIX_COMBINE_DEINTERLEAVE_FULL tmpq, lutq
    add outq, 8*mmsize
    add rtabq, 4*mmsize
    sub itabq, 4*mmsize
    sub lenq, 4*mmsize
    jg .synth_deinterleave

    RET

; 64-point deinterleave which only has to load 4 registers =====================
.64pt_deint:
    SPLIT_RADIX_COMBINE_LITE 1, m0, m1, tx1_e0, tx2_e0, tw_e, tw_o, tmp1, tmp2
    SPLIT_RADIX_COMBINE_HALF 0, m2, m3, tx1_o0, tx2_o0, tw_e, tw_o, tmp1, tmp2, tw_e

    unpcklpd tmp1, m0, m2
    unpcklpd tmp2, m1, m3
    unpcklpd tw_o, tx1_e0, tx1_o0
    unpcklpd tw_e, tx2_e0, tx2_o0
    unpckhpd m0, m0, m2
    unpckhpd m1, m1, m3
    unpckhpd tx1_e0, tx1_e0, tx1_o0
    unpckhpd tx2_e0, tx2_e0, tx2_o0

    vextractf128 [outq +  0*mmsize +  0], tmp1,   0
    vextractf128 [outq +  0*mmsize + 16], m0,     0
    vextractf128 [outq +  4*mmsize +  0], tmp2,   0
    vextractf128 [outq +  4*mmsize + 16], m1,     0

    vextractf128 [outq +  8*mmsize +  0], tw_o,   0
    vextractf128 [outq +  8*mmsize + 16], tx1_e0, 0
    vextractf128 [outq +  9*mmsize +  0], tw_o,   1
    vextractf128 [outq +  9*mmsize + 16], tx1_e0, 1

    vperm2f128 tmp1, tmp1, m0, 0x31
    vperm2f128 tmp2, tmp2, m1, 0x31

    vextractf128 [outq + 12*mmsize +  0], tw_e,   0
    vextractf128 [outq + 12*mmsize + 16], tx2_e0, 0
    vextractf128 [outq + 13*mmsize +  0], tw_e,   1
    vextractf128 [outq + 13*mmsize + 16], tx2_e0, 1

    movaps tw_e,           [tab_64_float + mmsize]
    vperm2f128 tw_o, tw_o, [tab_64_float + 64 - 4*7 - mmsize], 0x23

    movaps m0, [outq +  1*mmsize]
    movaps m1, [outq +  3*mmsize]
    movaps m2, [outq +  5*mmsize]
    movaps m3, [outq +  7*mmsize]

    movaps [outq +  1*mmsize], tmp1
    movaps [outq +  5*mmsize], tmp2

    SPLIT_RADIX_COMBINE 0, m0, m2, m1, m3, tx1_e1, tx2_e1, tx1_o1, tx2_o1, tw_e, tw_o, \
                           tmp1, tmp2, tx2_o0, tx1_o0, tx2_e0, tx1_e0 ; temporary registers

    unpcklpd tmp1, m0, m1
    unpcklpd tmp2, m2, m3
    unpcklpd tw_e, tx1_e1, tx1_o1
    unpcklpd tw_o, tx2_e1, tx2_o1
    unpckhpd m0, m0, m1
    unpckhpd m2, m2, m3
    unpckhpd tx1_e1, tx1_e1, tx1_o1
    unpckhpd tx2_e1, tx2_e1, tx2_o1

    vextractf128 [outq +  2*mmsize +  0], tmp1,   0
    vextractf128 [outq +  2*mmsize + 16], m0,     0
    vextractf128 [outq +  3*mmsize +  0], tmp1,   1
    vextractf128 [outq +  3*mmsize + 16], m0,     1

    vextractf128 [outq +  6*mmsize +  0], tmp2,   0
    vextractf128 [outq +  6*mmsize + 16], m2,     0
    vextractf128 [outq +  7*mmsize +  0], tmp2,   1
    vextractf128 [outq +  7*mmsize + 16], m2,     1

    vextractf128 [outq + 10*mmsize +  0], tw_e,   0
    vextractf128 [outq + 10*mmsize + 16], tx1_e1, 0
    vextractf128 [outq + 11*mmsize +  0], tw_e,   1
    vextractf128 [outq + 11*mmsize + 16], tx1_e1, 1

    vextractf128 [outq + 14*mmsize +  0], tw_o,   0
    vextractf128 [outq + 14*mmsize + 16], tx2_e1, 0
    vextractf128 [outq + 15*mmsize +  0], tw_o,   1
    vextractf128 [outq + 15*mmsize + 16], tx2_e1, 1

    RET
%endmacro

%if ARCH_X86_64
FFT_SPLIT_RADIX_FN avx,  float,    0
FFT_SPLIT_RADIX_FN avx,  ns_float, 1
FFT_SPLIT_RADIX_FN fma3, float,    0
FFT_SPLIT_RADIX_FN fma3, ns_float, 1
%endif
