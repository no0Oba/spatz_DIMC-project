#include <stdio.h>
#include "printf.h"
#include <snrt.h>

// Choose constants that satisfy your layout imm12[11:7] = 0.
// Example: k_row=5, sec=2  => IMM = (5<<2) | 2 = 0x16
#define IMM1 0x00
#define IMM2 0x01
#define IMM3 0x02
#define IMM4 0x03
#define IMM5 0x000
#define IMM6 0x080
#define IMM7 0x100
#define IMM8 0x180


int Filter[8] = {42,43,44,45,46,47,48,49};
int FilterCopy[8] = {0,0,0,0,0,0,0,0};
int vl;

int *a;
int *b;
// Set vector length configuration (e32 = 32-bit elements, m8 = LMUL=8)
static inline void set_vector_length(int len) {
   
    asm volatile("vsetvli %0, %1, e32, m8, ta, ma" : "=r"(vl) : "r"(len));
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F1(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM1)
    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F2(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM2)
    );
   
    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F3(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM3)
    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F4(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM4)
    );

    
    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K1(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM1)
    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K2(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM2)
    );

    
    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K3(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM3)
    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K4(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM4)
    );

    
    return x;
}

// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct_00(int in) {
    int out=0;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM5)
    );
    return out;
}
// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct_01(int in) {
    int out=0;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM6)
    );
    return out;
}
// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct_10(int in) {
    int out=0;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM7)
    );
    return out;
}

// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct_11(int in) {
    int out=0;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 5, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM8)
    );
    return out;
}


// Function to load data into VRF (v0) using `vle32.v`
static inline void load_to_vrf(int *src) {
    // Load 8 32-bit ints from Filter into v0 (VRF)
    asm volatile("vle32.v v0, (%0)" :: "r"(src));
}

// Function to store data from VRF (v0) back to memory
static inline void store_from_vrf(int *dst) {
    // Store 8 32-bit ints from v0 (VRF) into Filter
    asm volatile("vse32.v v0, (%0)" :: "r"(dst));
}

int main() {

    const unsigned int cid = snrt_cluster_core_idx();

    
    // Initialize matrices
    if (cid == 0) {

        a = (int *)snrt_l1alloc(8 * sizeof(int));
        b = (int *)snrt_l1alloc(8 * sizeof(int));
        
        snrt_dma_start_1d(a, Filter, 8 * sizeof(int));
        snrt_dma_start_1d(b, FilterCopy, 8 * sizeof(int));
        snrt_dma_wait_all();
    }

    // Wait for all cores to finish
    snrt_cluster_hw_barrier();


     // Set vector length and configuration (Example: using Filter's size)
    set_vector_length(8);

    // Load data from memory to VRF (v0)
    load_to_vrf(a);

    // Optional: Perform your DIMC operation or further operations on the vector register (v0)
    
    // Store data back from VRF (v0) to Filter array
    store_from_vrf(b);

    // Verify the stored data (for demonstration purposes)
    printf("Filter after DIMC and store:\n");
    for (int i = 0; i < 8; i++) {
        printf("[%d] original=%d  copy=%d\n", i, a[i], b[i]);
    }

    printf("Configured VL = %d\n", vl);
    
     int val = 0;
     int val2= 2;
    int r1 = dimc_single_F1(val);
    int r2 = dimc_single_F2(val);
    int r5 = dimc_single_K1(val);
    int r6 = dimc_single_K2(val);

    // Wait for completion before issuing more
    //snrt_cluster_hw_barrier();  // Hardware barrier
    int r3 = dimc_single_F3(val);
    int r4 = dimc_single_F4(val);
    int r7 = dimc_single_K3(val);
    int r8 = dimc_single_K4(val);
    
    // Wait for completion before issuing more
    //snrt_cluster_hw_barrier();  // Hardware barrier
    int r9 = dimc_distinct_00(val);
    int r10 = dimc_distinct_01(val);
    int r11 = dimc_distinct_10(val);    
    int r12 = dimc_distinct_11(val);

    // printf("DIMC test: IMM=0x%x (val=%d) -> single=%d, distinct=%d\n",
    //        IMM, val, r1, r2);

    printf("DIMC test: IMM=0x (val=%d) -> single=%d, distinct=%d\n", val, r1, r2);
   

    return 0;
}