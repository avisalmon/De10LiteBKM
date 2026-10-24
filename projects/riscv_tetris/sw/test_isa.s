# ISA smoke test: every instruction class, the memory map, and a known final state.
# Runs on the simulator and on the RTL; the traces must match. Ends with EXIT = 0 if every check passed,
# else EXIT = the number of the first failed check (shown on the LEDs too).
        .text
start:
        li      sp, 0x8000              # stack at the top of the RAM
        li      s1, 0                   # check number
        li      s2, 0x20000000          # IO base

# 1: arithmetic and logic
        addi    s1, s1, 1
        li      t0, 1234
        li      t1, -5678
        add     t2, t0, t1              # -4444
        li      t3, -4444
        bne     t2, t3, fail
        sub     t2, t0, t1              # 6912
        li      t3, 6912
        bne     t2, t3, fail
        xor     t2, t0, t1
        li      t3, 0xFFFFED00          # 1234 ^ -5678
        bne     t2, t3, fail
        or      t2, t0, t1
        and     t4, t0, t1
        add     t2, t2, t4              # (a|b)+(a&b) == a+b
        li      t3, -4444
        bne     t2, t3, fail
# 2: shifts
        addi    s1, s1, 1
        li      t0, 0x80000001
        srli    t1, t0, 1
        li      t3, 0x40000000
        bne     t1, t3, fail
        srai    t1, t0, 1
        li      t3, 0xC0000000
        bne     t1, t3, fail
        slli    t1, t0, 4
        li      t3, 0x10
        bne     t1, t3, fail
        li      t4, 31
        sll     t1, t0, t4
        li      t3, 0x80000000
        bne     t1, t3, fail
        sra     t1, t0, t4
        li      t3, -1
        bne     t1, t3, fail
        srl     t1, t0, t4
        li      t3, 1
        bne     t1, t3, fail
# 3: compares
        addi    s1, s1, 1
        li      t0, -1
        li      t1, 1
        slt     t2, t0, t1              # -1 < 1 signed: 1
        beqz    t2, fail
        sltu    t2, t0, t1              # 0xFFFFFFFF < 1 unsigned: 0
        bnez    t2, fail
        slti    t2, t0, 0
        beqz    t2, fail
        sltiu   t2, t1, 2
        beqz    t2, fail
        bge     t0, t1, fail
        bgeu    t1, t0, fail
        blt     t1, t0, fail
        bltu    t0, t1, fail
# 4: loads and stores of every size, signed and unsigned
        addi    s1, s1, 1
        la      t0, scratch
        li      t1, 0x89ABCDEF
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        bne     t2, t1, fail
        lb      t2, 0(t0)               # 0xEF sign-extended
        li      t3, 0xFFFFFFEF
        bne     t2, t3, fail
        lbu     t2, 0(t0)
        li      t3, 0xEF
        bne     t2, t3, fail
        lh      t2, 2(t0)               # 0x89AB sign-extended
        li      t3, 0xFFFF89AB
        bne     t2, t3, fail
        lhu     t2, 2(t0)
        li      t3, 0x89AB
        bne     t2, t3, fail
        sb      zero, 1(t0)             # 0x89AB00EF
        sh      t1, 2(t0)               # halves: low half of t1 = CDEF -> 0xCDEF00EF
        lw      t2, 0(t0)
        li      t3, 0xCDEF00EF
        bne     t2, t3, fail
        lw      t2, table + 8           # symbol form: third word of the table
        li      t3, 30
        bne     t2, t3, fail
# 5: jal / jalr / return, and auipc
        addi    s1, s1, 1
        li      a0, 7
        call    twice
        li      t3, 14
        bne     a0, t3, fail
        la      t0, twice
        jalr    ra, t0, 0
        li      t3, 28
        bne     a0, t3, fail
        auipc   t2, 0                   # t2 = the address of this instruction
        la      t3, after_auipc         # 2 words
        addi    t3, t3, -16             # auipc (4) + la (8) + addi (4) before the label
after_auipc:
        bne     t2, t3, fail
# 6: the text screen and the I/O registers
        addi    s1, s1, 1
        li      t0, 0x10000000
        li      t1, 0x0F41              # 'A', white on black
        sw      t1, 0(t0)
        li      t1, 0x1E80              # a full block, yellow on blue, row 1 col 2 -> cell 82
        sw      t1, 328(t0)
        li      t1, 0x123456
        sw      t1, 0x0C(s2)            # HEX
        li      t1, 0x155
        sw      t1, 0x10(s2)            # LEDs
        lw      t1, 0x04(s2)            # FRAME: readable
        lw      t1, 0x20(s2)            # CYCLES: readable
        li      t1, 'O'
        sw      t1, 0x18(s2)            # UART
        li      t1, 'K'
        sw      t1, 0x18(s2)
        li      t1, 10
        sw      t1, 0x18(s2)
# 7: a loop: sum 1..100 = 5050
        addi    s1, s1, 1
        li      t0, 0
        li      t1, 1
        li      t2, 100
loop:   add     t0, t0, t1
        addi    t1, t1, 1
        ble     t1, t2, loop
        li      t3, 5050
        bne     t0, t3, fail
        sw      t0, 0x0C(s2)            # 5050 in hex on the digits: 0013BA
# done
        sw      zero, 0x10(s2)
        sw      zero, 0x24(s2)          # EXIT 0
        j       .

fail:   sw      s1, 0x10(s2)            # the failed check on the LEDs
        sw      s1, 0x24(s2)            # EXIT n
        j       .

twice:  add     a0, a0, a0
        ret

        .data
        .align  2
table:  .word   10, 20, 30, 40
scratch: .space 16
msg:    .asciz  "hello"
