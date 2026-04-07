#include "benchmark.c"
#include <debug.h>
#include <stdio.h>
#include "printf.h"
#include <snrt.h>

int Filter1[256] = {
    0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,
    4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,
    6,6,6,6,6,6,6,6,7,7,7,7,7,7,7,7,
    8,8,8,8,8,8,8,8,9,9,9,9,9,9,9,9,
    10,10,10,10,10,10,10,10,11,11,11,11,11,11,11,11,
    12,12,12,12,12,12,12,12,13,13,13,13,13,13,13,13,
    14,14,14,14,14,14,14,14,15,15,15,15,15,15,15,15,
    16,16,16,16,16,16,16,16,17,17,17,17,17,17,17,17,
    18,18,18,18,18,18,18,18,19,19,19,19,19,19,19,19,
    20,20,20,20,20,20,20,20,21,21,21,21,21,21,21,21,
    22,22,22,22,22,22,22,22,23,23,23,23,23,23,23,23,
    24,24,24,24,24,24,24,24,25,25,25,25,25,25,25,25,
    26,26,26,26,26,26,26,26,27,27,27,27,27,27,27,27,
    28,28,28,28,28,28,28,28,29,29,29,29,29,29,29,29,
    30,30,30,30,30,30,30,30,31,31,31,31,31,31,31,31,
    };

int Filter2[256] = {
    0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,
    4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,
    6,6,6,6,6,6,6,6,7,7,7,7,7,7,7,7,
    8,8,8,8,8,8,8,8,9,9,9,9,9,9,9,9,
    10,10,10,10,10,10,10,10,11,11,11,11,11,11,11,11,
    12,12,12,12,12,12,12,12,13,13,13,13,13,13,13,13,
    14,14,14,14,14,14,14,14,15,15,15,15,15,15,15,15,
    16,16,16,16,16,16,16,16,17,17,17,17,17,17,17,17,
    18,18,18,18,18,18,18,18,19,19,19,19,19,19,19,19,
    20,20,20,20,20,20,20,20,21,21,21,21,21,21,21,21,
    22,22,22,22,22,22,22,22,23,23,23,23,23,23,23,23,
    24,24,24,24,24,24,24,24,25,25,25,25,25,25,25,25,
    26,26,26,26,26,26,26,26,27,27,27,27,27,27,27,27,
    28,28,28,28,28,28,28,28,29,29,29,29,29,29,29,29,
    30,30,30,30,30,30,30,30,31,31,31,31,31,31,31,31,
    };

int FilterCopy[256] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
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
int *c;

// Set vector length configuration (e32 = 32-bit elements, m2 = LMUL=2)
static inline void set_vector_length(int len) {
    asm volatile("vsetvli %0, %1, e32, m1, ta, ma" : "=r"(vl) : "r"(len));
}

static inline void dimc_r_type(int vd, int vs1, int vs2, int funct7) {
    uint32_t insn = (funct7 << 25) |
                    (vs2 << 20) |
                    (vs1 << 15) |
                    (6 << 12) |
                    (vd << 7) |
                    0x5F;
    
    asm volatile(".word %0" : : "i"(insn)); //word %0 : : "i"(insn)
}
 /*   
   static inline void dimc_r_type(int vd, int vs1, int vs2, int funct7)
{
    uint32_t insn =
        (funct7 << 25) |
        (vs2 << 20) |
        (vs1 << 15) |
        (6 << 12) |
        (vd << 7) |
        0x5F;

    asm volatile(
        ".word %0"
        :
        : "r"(insn)
        : "memory"
    );
}
*/
static inline void load_to_vrf_MatrixA(int *src) {
    // Load 16 32-bit ints from Filter into v0-V2 (VRF)
    asm volatile("vle32.v v0, (%0)" :: "r"(src));   
    //asm volatile("vle32.v v1, (%0)" :: "r"(src+16));  //when VLEN of VRF 1024 to fill all 4 sec
}

static inline void load_to_vrf_MatrixA2(int *src) {
    // Load 16 32-bit ints from Filter into v0-V2 (VRF)
    asm volatile("vle32.v v18, (%0)" :: "r"(src));   
    //asm volatile("vle32.v v19, (%0)" :: "r"(src+16)); //when VLEN of VRF 1024 to fill all 4 sec
}

static inline void load_to_vrf_PSIN(int *src) {
    // Load 16 32-bit ints from Filter into v0-V2 (VRF)
    asm volatile("vle32.v v31, (%0)" :: "r"(src));   
    //asm volatile("vle32.v v19, (%0)" :: "r"(src+16)); //when VLEN of VRF 1024 to fill all 4 sec
}


static inline void load_to_vrf_MatrixB(int *src) {
    // Load 16 32-bit ints from Filter into v2-V18 (VRF)
    asm volatile("vle32.v v2, (%0)" :: "r"(src));      
    //asm volatile("vle32.v v3, (%0)" :: "r"(src+16)); //when VLEN of VRF 1024 to fill all 4 sec  
    asm volatile("vle32.v v3, (%0)" :: "r"(src+32));   
    //asm volatile("vle32.v v5, (%0)" :: "r"(src+48));   
    asm volatile("vle32.v v4, (%0)" :: "r"(src+64));   
    //asm volatile("vle32.v v7, (%0)" :: "r"(src+80));   
    asm volatile("vle32.v v5, (%0)" :: "r"(src+96));   
    //asm volatile("vle32.v v9, (%0)" :: "r"(src+112));   
    asm volatile("vle32.v v6, (%0)" :: "r"(src+128)); 
    //asm volatile("vle32.v v11, (%0)" :: "r"(src+144)); 
    asm volatile("vle32.v v7, (%0)" :: "r"(src+160)); 
    //asm volatile("vle32.v v13, (%0)" :: "r"(src+176)); 
    asm volatile("vle32.v v8, (%0)" :: "r"(src+192)); 
    //asm volatile("vle32.v v15, (%0)" :: "r"(src+208)); 
    asm volatile("vle32.v v9, (%0)" :: "r"(src+224)); 
    //asm volatile("vle32.v v17, (%0)" :: "r"(src+240));
    
    }

    static inline void store_from_vrf_MAtrixC(int *dst) {
    // Store 8 32-bit ints from v0 (VRF) into Filter
    asm volatile("vse32.v v31, (%0)" :: "r"(dst));
    }

int main() {

    const unsigned int cid = snrt_cluster_core_idx();

    
    // Initialize matrices
    if (cid == 0) {

        a = (int *)snrt_l1alloc(256 * sizeof(int));
        b = (int *)snrt_l1alloc(256 * sizeof(int));
        c = (int *)snrt_l1alloc(256 * sizeof(int));
        
        //printf("b = %x\n",b);
        //printf("b = %x\n",b+16);

        snrt_dma_start_1d(a, Filter1, 256 * sizeof(int));
        snrt_dma_start_1d(b, Filter2, 256 * sizeof(int));
        snrt_dma_start_1d(c, FilterCopy, 256 * sizeof(int));
        snrt_dma_wait_all();
    }

    unsigned int timer_start, timer_end, timer;
    // Reset timer
    timer = (unsigned int)-1;

    
    // Wait for all cores to finish
    snrt_cluster_hw_barrier();

     // Set vector length and configuration (Example: using Filter's size)
    if(cid == 0){
        set_vector_length(16);
        
        timer_start = benchmark_get_cycle();
        // MATRIX MULTIPLICATION A * B = C
        start_kernel();
        for (int i = 0; i < 1000; i++){
        asm volatile("vle32.v v31, (%0)" :: "r"(a));
        }
        

        
        stop_kernel();

        // End timer and check if new best runtime
        timer_end = benchmark_get_cycle();
      
        unsigned int timer_temp = timer_end - timer_start;
        printf("The execution took %u cycles.\n", timer_temp);
        printf("Start time : %u cycles\n", timer_start);
        printf("End time   : %u cycles\n", timer_end);
        /*
        for (int tb = 0; tb < 2; tb++) {

         // Load B tile
         load_to_vrf_MatrixB(b + tb * 16);

         // Initial double buffer preload
         load_to_vrf_MatrixA(a + tb * 16);
         load_to_vrf_MatrixA2(a + 32 + tb * 16);

            for (int i = 0; i < 8; i++) {

                int a_next = (i + 2) * 32 + tb * 16;

                // Compute
                dimc_r_type(31, 0, 2, 11);
                
                // Prefetch next tile (ping-pong A / A2)
                if (a_next < 256 + tb * 16) {
                    if (i % 2 == 0)
                        load_to_vrf_MatrixA(a + a_next);
                    else
                        load_to_vrf_MatrixA2(a + a_next);
                }

                snrt_cluster_hw_barrier();

               
                    store_from_vrf_MAtrixC(c + i * 8);                
            }
        }
      */
      
    /*  
        //MATRIX MULTIPLICATION A * B = C
        load_to_vrf_MatrixA(a); //1st compute Feature 
        load_to_vrf_MatrixB(b);
        //2st compute Feature +32 for 1024 VLEN
        load_to_vrf_MatrixA2(a+32); //2nd compute Feature +64 for 1024 VLEN
        dimc_r_type(10, 0, 2, 3);   //1st R-type: v0 = MACVV(v1, v2) with funct7=11 with partial sum funct7 = 3 without PSIN
        
        load_to_vrf_MatrixA(a+64);  //3rd compute Feature +64 for 1024 VLEN
        dimc_r_type(11, 18, 2, 3); //2nd

        
        load_to_vrf_MatrixA2(a+96); //4th compute Feature +96 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(12, 0, 2, 3);   //3rd R-type: v0 = MACVV(v1, v2) with funct7=11 
        
        load_to_vrf_MatrixA(a+128); //5th compute Feature +128 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(13, 18, 2, 3);   //4th R-type: v0 = MACVV(v1, v2) with funct7=10
        
        load_to_vrf_MatrixA2(a+160); //6th compute Feature +160 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(14, 0, 2, 3);   //5th R-type: v0 = MACVV(v1, v2) with funct7=10
        
        load_to_vrf_MatrixA(a+192);  //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(15, 18, 2, 3);   //6th R-type: v0 = MACVV(v1, v2) with funct7=10
        
        //store_from_vrf_MAtrixC(c+32);
        
        load_to_vrf_MatrixA2(a+224); //8th compute Feature +224 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(16, 0, 2, 3);   //7th R-type: v0 = MACVV(v1, v2) with funct7=10
        
        load_to_vrf_MatrixA(a+16); //9th compute Feature +16 for 1024 VLEN
        dimc_r_type(17, 18, 2, 3);   //8th R-type: v0 = MACVV(v1, v2) with funct7=10
        
        load_to_vrf_MatrixB(b+16);
        //
        load_to_vrf_MatrixA2(a+48); //7th compute Feature +48+ for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(10, 0, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v10");
        store_from_vrf_MAtrixC(c);
        
        load_to_vrf_MatrixA(a+80); //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(11, 18, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v11");
        store_from_vrf_MAtrixC(c+8);

        load_to_vrf_MatrixA2(a+112); //7th compute Feature +192 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(12, 0, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v12");
        store_from_vrf_MAtrixC(c+16);

        load_to_vrf_MatrixA(a+144); //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(13, 18, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10

        asm volatile("vmv.v.v v31, v13");
        snrt_cluster_hw_barrier();
        store_from_vrf_MAtrixC(c+24);

        load_to_vrf_MatrixA2(a+176); //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(14, 0, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v14");
        snrt_cluster_hw_barrier();
        store_from_vrf_MAtrixC(c+32);

        load_to_vrf_MatrixA(a+208); //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(15, 18, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v15");
        store_from_vrf_MAtrixC(c+40);

        load_to_vrf_MatrixA2(a+208); //7th compute Feature +192 for 1024 VLEN
        snrt_cluster_hw_barrier();
        dimc_r_type(16, 0, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
       
        asm volatile("vmv.v.v v31, v16");
        store_from_vrf_MAtrixC(c+48);

        load_to_vrf_MatrixA(a+240); //7th compute Feature +192 for 1024 VLEN
        dimc_r_type(17, 18, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
        
        asm volatile("vmv.v.v v31, v17");
        store_from_vrf_MAtrixC(c+56);
        
        for (int i = 0; i < 64; i++) {
            printf("c[%d] = %d\n", i, c[i]);
        }
        
    /*load_to_vrf_MatrixA2(a+112); //8th compute Feature +224 for 1024 VLEN
    //load_to_vrf_MatrixB(b);
    dimc_r_type(31, 0, 2, 3);   // R-type: v0 = MACVV(v1, v2) with funct7=10
    
    store_from_vrf_MAtrixC(c+48);

    load_to_vrf_MatrixA(a+128);
    
    //load_to_vrf_MatrixB(b);
    dimc_r_type(31, 0, 2, 3);   // R-type: v0 = MACVV(v1, v2) with funct7=10
    store_from_vrf_MAtrixC(c+56);
    //load_to_vrf_PSIN(c);
        int *src = b+16;
        load_to_vrf_MatrixA2(a+16);
        
        load_to_vrf_MatrixB(b+16);

        dimc_r_type(10, 18, 2, 11);*/

    // Optional: Perform your DIMC operation or further operations on the vector register (v0)
    
    // printf("Configured VL = %d\n", vl);
    
      // v0 = v0 + (v1 × v2) with mode 0
        //__asm__ volatile ("nop");   // 1-cycle bubble                   
    //dimc_r_type(1, 3, 2, 11);   // R-type: v0 = MACVV(v1, v2) with funct7=10
    }
    snrt_cluster_hw_barrier();
    return 0;
}