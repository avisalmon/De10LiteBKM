# C runtime for the RV32I SoC: start-up, and the routines the compiler calls for * / % (no multiplier in RV32I).
# tools/build.py puts this first in the image, so _start is at address 0 (the reset vector).
        .text
        .globl  _start
_start:
        li      sp, 0x8000              # the stack: top of the 32 KB RAM, growing down
        la      t0, __bss_start         # zero the uninitialised globals (a reset re-runs the program without
        la      t1, __bss_end           # reloading the RAM, so they must not keep old values)
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:      call    main
        li      t0, 0x20000024          # IO_EXIT: main's return value is the exit code
        sw      a0, 0(t0)
3:      j       3b

# a0 = a0 * a1 (low 32 bits; works for signed and unsigned alike), shift-and-add
        .globl  __mul
__mul:
        mv      t0, a0
        mv      t1, a1
        li      a0, 0
1:      beqz    t1, 2f
        andi    t2, t1, 1
        beqz    t2, 3f
        add     a0, a0, t0
3:      slli    t0, t0, 1
        srli    t1, t1, 1
        j       1b
2:      ret

# unsigned a0 = a0 / a1, a1 = a0 % a1 (restoring division, 32 steps); division by zero gives -1, remainder a0
        .globl  __udivmod
__udivmod:
        beqz    a1, 9f
        mv      t0, a0                  # dividend
        mv      t1, a1                  # divisor
        li      a0, 0                   # quotient
        li      a1, 0                   # remainder
        li      t2, 32
1:      slli    a1, a1, 1
        srli    t3, t0, 31
        or      a1, a1, t3
        slli    t0, t0, 1
        slli    a0, a0, 1
        bltu    a1, t1, 2f
        sub     a1, a1, t1
        ori     a0, a0, 1
2:      addi    t2, t2, -1
        bnez    t2, 1b
        ret
9:      mv      a1, a0
        li      a0, -1
        ret

        .globl  __udiv
__udiv: j       __udivmod               # a0 = quotient (a1 = remainder, ignored)

        .globl  __umod
__umod: addi    sp, sp, -4
        sw      ra, 0(sp)
        call    __udivmod
        mv      a0, a1
        lw      ra, 0(sp)
        addi    sp, sp, 4
        ret

# signed a0 = a0 / a1 (truncating toward zero, like C)
        .globl  __div
__div:  addi    sp, sp, -4
        sw      ra, 0(sp)
        xor     t4, a0, a1              # sign of the result
        bgez    a0, 1f
        neg     a0, a0
1:      bgez    a1, 2f
        neg     a1, a1
2:      call    __udivmod
        bgez    t4, 3f
        neg     a0, a0
3:      lw      ra, 0(sp)
        addi    sp, sp, 4
        ret

# signed a0 = a0 % a1 (the sign of the dividend, like C)
        .globl  __mod
__mod:  addi    sp, sp, -4
        sw      ra, 0(sp)
        mv      t5, a0                  # sign of the dividend
        bgez    a0, 1f
        neg     a0, a0
1:      bgez    a1, 2f
        neg     a1, a1
2:      call    __udivmod
        mv      a0, a1
        bgez    t5, 3f
        neg     a0, a0
3:      lw      ra, 0(sp)
        addi    sp, sp, 4
        ret
