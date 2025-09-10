// DIMC_test.c
#include <stdio.h>
#include "printf.h"


// Choose constants that satisfy your layout imm12[11:7] = 0.
// Example: k_row=5, sec=2  => IMM = (5<<2) | 2 = 0x16
#define IMM 0x16

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single(int x) {
    asm volatile(
        // professor-style: constant immediate via "I"(IMM)
        ".insn i 0x6B, 4, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM)
    );

    // OPTIONAL: exact same thing with literal in the template (no operand):
    // asm volatile(".insn i 0x13, 0, %0, %0, 0x16\n" : "+r"(x));

    return x;
}

// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct(int in) {
    int out;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM)
    );
    return out;
}

int main() {
    int val = 20;
    int r1 = dimc_single(val);
    int r2 = dimc_distinct(val);

    // printf("DIMC test: IMM=0x%x (val=%d) -> single=%d, distinct=%d\n",
    //        IMM, val, r1, r2);

    printf("DIMC test: IMM=0x (val=%d) -> single=%d, distinct=%d\n", val, r1, r2);

    return 0;
}
