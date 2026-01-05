// DIMC_test.c

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
#define IMM6 0x280
#define IMM7 0x500
#define IMM8 0x780


int Filter[512] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
                2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,
                4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
                6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
                10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,
                11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,
                12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,
                13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,
                14,14,14,14,14,14,14,14,14,14,14,14,14,14,14,14,
                15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
                16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
                17,17,17,17,17,17,17,17,17,17,17,17,17,17,17,17,
                18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,
                19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,
                20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,
                21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,
                22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,
                23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,
                24,24,24,24,24,24,24,24,24,24,24,24,24,24,24,24,
                25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,
                26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,26,
                27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,
                28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,
                29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,
                30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,
                31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31};
int FilterCopy[512] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                       0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 
                    };
int vl;

int *a;
int *b;

// Set vector length configuration (e32 = 32-bit elements, m2 = LMUL=2)
static inline void set_vector_length(int len) {
   
    asm volatile("vsetvli %0, %1, e32, m2, ta, ma" : "=r"(vl) : "r"(len));
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F1(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM1)  
        : "v0"    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F2(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM2)  
        : "v0"    );
   
        return x;
    }

    // Variant A: single in/out variable (rs1 == rd)
    static inline int dimc_single_F3(int x) {
        asm volatile(
            
            ".insn i 0x6B, 1, v0, v%0, %1"
            :
            : "i"(x), "I"(IMM3)  
            : "v0"    );

        return x;
    }

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_F4(int x) {
    asm volatile(
    
        ".insn i 0x6B, 1, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM4)  
        : "v0"    );
    
    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K1(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM1)  
        : "v0"    );

    return x;
}

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single_K2(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM2)  
        : "v0"    );

    return x;
}

// Variant A: single in/out variable (vs1 == vd)
static inline int dimc_single_K3(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM3)  
        : "v0"    );

    return x;
}

static inline int dimc_single_K4(int x) {
    asm volatile(
    
        ".insn i 0x6B, 2, v0, v%0, %1"
        :
        : "i"(x), "I"(IMM4)  
        : "v0"    );

    return x;
}



// Variant B: distinct input and output variables (rs1 != rd)
static inline void dimc_distinct_00(int in) {
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
            ".insn i 0x6B, 4, v0, v%0, %1"
        :
        : "i"(in), "I"(IMM5)
        : "v0"    
    );
}
// Variant B: distinct input and output variables (rs1 != rd)
static inline void dimc_distinct_01(int in) {
    
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
      ".insn i 0x6B, 4, v0, v%0, %1"
        :
        : "i"(in), "I"(IMM6)
        : "v0"     // Clobber list must include v1 now    
    );
}
// Variant B: distinct input and output variables (rs1 != rd)
static inline void dimc_distinct_10(int in) {
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
       ".insn i 0x6B, 4, v0, v%0, %1"
        :
        : "i"(in), "I"(IMM7)
        : "v0"     // Clobber list must include v1 now    
    );
}

// Variant B: distinct input and output variables (rs1 != rd)
static inline void dimc_distinct_11(int in) {
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
          ".insn i 0x6B, 5, v0, v%0, %1"
        :
        : "i"(in), "I"(IMM8)
        : "v0"     // Clobber list must include v1 now    
    );
}

/*
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

// Variant A: single in/out variable (rs1 == rd)
static inline int dimc_single(int x) {
    asm volatile(
    
        ".insn i 0x6B, 4, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM)
    );    
    return x;
}
*/

// Function to load data into VRF (v0) using `vle32.v`
static inline void load_to_vrf(int *src) {
    // Load 8 32-bit ints from Filter into v0 (VRF)
    asm volatile("vle32.v v0, (%0)" :: "r"(src));
    asm volatile("vle32.v v1, (%0)" :: "r"(src+16)); 
    asm volatile("vle32.v v2, (%0)" :: "r"(src+32));
    asm volatile("vle32.v v3, (%0)" :: "r"(src+48)); 
    asm volatile("vle32.v v4, (%0)" :: "r"(src+64));
    asm volatile("vle32.v v5, (%0)" :: "r"(src+80)); 
    asm volatile("vle32.v v6, (%0)" :: "r"(src+96));
    asm volatile("vle32.v v7, (%0)" :: "r"(src+112)); 
    asm volatile("vle32.v v8, (%0)" :: "r"(src+128));
    asm volatile("vle32.v v9, (%0)" :: "r"(src+144));    
    asm volatile("vle32.v v10, (%0)" :: "r"(src+160));
    asm volatile("vle32.v v11, (%0)" :: "r"(src+176)); 
    asm volatile("vle32.v v12, (%0)" :: "r"(src+192));
    asm volatile("vle32.v v13, (%0)" :: "r"(src+208)); 
    asm volatile("vle32.v v14, (%0)" :: "r"(src+224));
    asm volatile("vle32.v v15, (%0)" :: "r"(src+240)); 
    asm volatile("vle32.v v16, (%0)" :: "r"(src+256));
    asm volatile("vle32.v v17, (%0)" :: "r"(src+272)); 
    asm volatile("vle32.v v18, (%0)" :: "r"(src+288));
    asm volatile("vle32.v v19, (%0)" :: "r"(src+304)); 
    asm volatile("vle32.v v20, (%0)" :: "r"(src+320));
    asm volatile("vle32.v v21, (%0)" :: "r"(src+336)); 
    asm volatile("vle32.v v22, (%0)" :: "r"(src+352));
    asm volatile("vle32.v v23, (%0)" :: "r"(src+368)); 
    asm volatile("vle32.v v24, (%0)" :: "r"(src+384));
    asm volatile("vle32.v v25, (%0)" :: "r"(src+400)); 
    asm volatile("vle32.v v26, (%0)" :: "r"(src+416));
    asm volatile("vle32.v v27, (%0)" :: "r"(src+432)); 
    asm volatile("vle32.v v28, (%0)" :: "r"(src+448));
    asm volatile("vle32.v v29, (%0)" :: "r"(src+464)); 
    asm volatile("vle32.v v30, (%0)" :: "r"(src+480));
    asm volatile("vle32.v v31, (%0)" :: "r"(src+496));

}

// Function to store data from VRF (v0) back to memory
static inline void store_from_vrf(int *dst) {
    // Store 8 32-bit ints from v0 (VRF) into Filter
    asm volatile("vse32.v v0, (%0)" :: "r"(dst));
    asm volatile("vse32.v v1, (%0)" :: "r"(dst+16));
    asm volatile("vse32.v v2, (%0)" :: "r"(dst+32));
    asm volatile("vse32.v v3, (%0)" :: "r"(dst+48));
    asm volatile("vse32.v v4, (%0)" :: "r"(dst+64));
    asm volatile("vse32.v v5, (%0)" :: "r"(dst+80));
    asm volatile("vse32.v v6, (%0)" :: "r"(dst+96));
    asm volatile("vse32.v v7, (%0)" :: "r"(dst+112));
    asm volatile("vse32.v v8, (%0)" :: "r"(dst+128));
    asm volatile("vse32.v v9, (%0)" :: "r"(dst+144));
    asm volatile("vse32.v v10, (%0)" :: "r"(dst+160));
    asm volatile("vse32.v v11, (%0)" :: "r"(dst+176));
    asm volatile("vse32.v v12, (%0)" :: "r"(dst+192));
    asm volatile("vse32.v v13, (%0)" :: "r"(dst+208));
    asm volatile("vse32.v v14, (%0)" :: "r"(dst+224));
    asm volatile("vse32.v v15, (%0)" :: "r"(dst+240));
    asm volatile("vse32.v v16, (%0)" :: "r"(dst+256));
    asm volatile("vse32.v v17, (%0)" :: "r"(dst+272));
    asm volatile("vse32.v v18, (%0)" :: "r"(dst+288));
    asm volatile("vse32.v v19, (%0)" :: "r"(dst+304));
    asm volatile("vse32.v v20, (%0)" :: "r"(dst+320));
    asm volatile("vse32.v v21, (%0)" :: "r"(dst+336));
    asm volatile("vse32.v v22, (%0)" :: "r"(dst+352));
    asm volatile("vse32.v v23, (%0)" :: "r"(dst+368));
    asm volatile("vse32.v v24, (%0)" :: "r"(dst+384));
    asm volatile("vse32.v v25, (%0)" :: "r"(dst+400));
    asm volatile("vse32.v v26, (%0)" :: "r"(dst+416));
    asm volatile("vse32.v v27, (%0)" :: "r"(dst+432));
    asm volatile("vse32.v v28, (%0)" :: "r"(dst+448));
    asm volatile("vse32.v v29, (%0)" :: "r"(dst+464));
    asm volatile("vse32.v v30, (%0)" :: "r"(dst+480));
    asm volatile("vse32.v v31, (%0)" :: "r"(dst+496));

}

int main() {

    const unsigned int cid = snrt_cluster_core_idx();

    
    // Initialize matrices
    if (cid == 0) {

        a = (int *)snrt_l1alloc(512 * sizeof(int));
        b = (int *)snrt_l1alloc(512 * sizeof(int));
        
        snrt_dma_start_1d(a, Filter, 512 * sizeof(int));
        snrt_dma_start_1d(b, FilterCopy, 512 * sizeof(int));
        snrt_dma_wait_all();
    }

    // Wait for all cores to finish
    snrt_cluster_hw_barrier();

     // Set vector length and configuration (Example: using Filter's size)
    set_vector_length(16);

    // Load data from memory to VRF (v0)
    load_to_vrf(a);

    // Optional: Perform your DIMC operation or further operations on the vector register (v0)
    
    // Store data back from VRF (v0) to Filter array
    store_from_vrf(b);

    // Verify the stored data (for demonstration purposes)
    printf("Filter after DIMC and store:\n");
    for (int i = 0; i < 32; i++) {
        printf("[%d] original=%d  copy=%d\n", i, a[i], b[i]);
    }

    printf("Configured VL = %d\n", vl);

     int val = 18;
     int val2= 1;
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
    dimc_distinct_00(val);
    dimc_distinct_01(val);
    dimc_distinct_10(val); 
    dimc_distinct_11(val2);

    // printf("DIMC test: IMM=0x%x (val=%d) -> single=%d, distinct=%d\n",
    //        IMM, val, r1, r2);

    //printf("DIMC test: IMM=0x (val=%d) -> single=%d, distinct=%d\n", val, r1, r2);
   

    return 0;
}


