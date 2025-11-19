// DIMC_test.c

#include <stdio.h>
#include "printf.h"
#include <snrt.h>

// Choose constants that satisfy your layout imm12[11:7] = 0.
// Example: k_row=5, sec=2  => IMM = (5<<2) | 2 = 0x16
#define IMM 0x25

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
static inline int dimc_single(int x) {
    asm volatile(
    
        ".insn i 0x6B, 4, %0, %0, %1\n"
        : "+r"(x)
        : "I"(IMM)
    );

    
    return x;
}

// Variant B: distinct input and output variables (rs1 != rd)
static inline int dimc_distinct(int in) {
    int out=0;
    // Any C variable is fine for rs1; only the immediate must be constant.
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(out)
        : "r"(in), "I"(IMM)
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

    int val = 22;
    int r1 = dimc_single(val);
    int r2 = dimc_distinct(val);

    // printf("DIMC test: IMM=0x%x (val=%d) -> single=%d, distinct=%d\n",
    //        IMM, val, r1, r2);

    printf("DIMC test: IMM=0x (val=%d) -> single=%d, distinct=%d\n", val, r1, r2);
    
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
    
    return 0;
}


/*
#include <stdio.h>
#include "printf.h"
#include <snrt.h>

int main() {
    const unsigned int cid = snrt_cluster_core_idx();

    int *vrf_row0 = (int *)snrt_l1alloc(sizeof(int));
    *vrf_row0 = 22;

    snrt_cluster_hw_barrier();

    asm volatile("vle32.v v0, (%0)" :: "r"(vrf_row0)); // load VRF row 0

    int result;
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(result)
        : "r"(0),       // rs1 = VRF row index 0
          "I"(0x24)      // immediate: row 0, sec 0, flags 0
    );

    printf("DIMC read value: %d\n", result);

    return 0;
}
*/

/*
#include <stdio.h>
#include "printf.h"
#include <snrt.h>

#define IMM 0x25

int main() {
    const unsigned int cid = snrt_cluster_core_idx();

    static int src_value = 22;   // stable in memory
    int *l1_row0 = NULL;

    if (cid == 0) {
        l1_row0 = (int *)snrt_l1alloc(sizeof(int));
        // DMA from main memory into L1 so vle32.v can read it
        snrt_dma_start_1d(l1_row0, &src_value, sizeof(int));
        snrt_dma_wait_all();
        printf("cid=%d src_addr=%p l1_addr=%p\n", cid, (void*)&src_value, (void*)l1_row0);
    }

    // sync all cores
    snrt_cluster_hw_barrier();

    // load L1 buffer into VRF row 0 (v0)
    asm volatile("vle32.v v0, (%0)" :: "r"(l1_row0));

    // small barrier to ensure VRF write completes before DIMC read
    snrt_cluster_hw_barrier();

    // Call DIMC with rs1 = 0 (VRF row 0)
    int dimc_out;
    asm volatile(
        ".insn i 0x6B, 4, %0, %1, %2\n"
        : "=r"(dimc_out)
        : "r"(0),     // rs1 = VRF row index 0  <-- VERY IMPORTANT
          "I"(IMM)    // immediate for DIMC config
    );

    printf("DIMC read value: %d\n", dimc_out);

    // Optional: store VRF back to L1 and print to confirm
    int *out_l1 = (int *)snrt_l1alloc(sizeof(int));
    asm volatile("vse32.v v0, (%0)" :: "r"(out_l1));
    snrt_cluster_hw_barrier();
    if (cid == 0) {
      printf("VRF row0 -> L1 value = %d\n", *out_l1);
    }

    return 0;
}
*/
