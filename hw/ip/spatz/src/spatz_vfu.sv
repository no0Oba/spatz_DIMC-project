// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Matheus Cavalcante, ETH Zurich
//
// The Vector Functional Unit (VFU) executes all arithmetic and logical
// vector instructions. It can be configured with a parameterizable amount
// of IPUs that work in parallel.

module spatz_vfu
  import spatz_pkg::*;
  import rvv_pkg::*;
  import cf_math_pkg::idx_width;
  import fpnew_pkg::*; #(
    /// FPU configuration.
    parameter fpu_implementation_t FPUImplementation = fpu_implementation_t'(0),
    // DIMC configuration
    parameter SECTION_WIDTH = 256 
  ) (
    input  logic             clk_i,   
    input  logic             rst_ni,
    input  logic [31:0]      hart_id_i,           //Multi-Hart Vector Processing (used in FPU)
    // Spatz req
    input  spatz_req_t       spatz_req_i,         //Incoming vector instruction operation
    input  logic             spatz_req_valid_i,   //Vector instruction request is valid
    output logic             spatz_req_ready_o,   //VFU ready to accept new instruction
    // VFU response
    output logic             vfu_rsp_valid_o,     //vector operation response is valid 
    input  logic             vfu_rsp_ready_i,     //VFU ready to receive response
    output vfu_rsp_t         vfu_rsp_o,           //Vector operation result output
    // VRF
    output vrf_addr_t        vrf_waddr_o,         //Vector register file write address
    output vrf_data_t        vrf_wdata_o,         //Vector register file write data
    output logic             vrf_we_o,            //Vector register file write enable
    output vrf_be_t          vrf_wbe_o,           //Vector register file write byte enable
    input  logic             vrf_wvalid_i,        //Vector register file write completed
    output spatz_id_t  [3:0] vrf_id_o,            //Vector register file transaction identifiers
    output vrf_addr_t  [2:0] vrf_raddr_o,         //Vector register file read addresses
    output logic       [2:0] vrf_re_o,            //Vector register file read enables
    input  vrf_data_t  [2:0] vrf_rdata_i,         //Vector register file read data
    input  logic       [2:0] vrf_rvalid_i,        //Vector register file read data valid
    // FPU side channel
    output status_t          fpu_status_o,        //Floating-point unit exception status
    // DIMC outputs
    output logic [23:0]      dimc_psout_o,
    output logic             dimc_sout_o,
    output logic [2:0]       dimc_res_out_o

    
  );
  
`include "common_cells/registers.svh"
 
    typedef struct packed {
    spatz_id_t id;          //Instruction identifier for tracking multiple in-flight operations

    vew_e vsew;             //Vector element width (8/16/32/64-bit) for operand sizing
    vlen_t vstart;          //Starting element index for partial vector operations

    // Encodes both the scalar RD and the VD address in the VRF
    vrf_addr_t vd_addr;     //Destination vector register address in VRF
    logic wb;               //Writeback flag (1=scalar result, 0=vector result)
    logic last;             //Final operation flag for multi-element instructions

    // Is this a narrowing instruction?
    logic narrowing;        //Narrowing operation flag (e.g., 64b→32b conversion)
    logic narrowing_upper;  //Upper/lower half selector for narrowing operations

    // Is this a reduction?
    logic reduction;        //Reduction operation flag (vector→scalar operations)
  } vfu_tag_t;

  ///////////////////////
  //  Operation queue  //
  ///////////////////////

  spatz_req_t spatz_req;
  logic       spatz_req_valid;
  logic       spatz_req_ready;
  
  // buffer for VFU is busy processing
  spill_register #(
    .T(spatz_req_t)
  ) i_operation_queue (
    .clk_i  (clk_i                                          ),
    .rst_ni (rst_ni                                         ),
    .data_i (spatz_req_i                                    ),
    .valid_i(spatz_req_valid_i && spatz_req_i.ex_unit == VFU),
    .ready_o(spatz_req_ready_o                              ),
    .data_o (spatz_req                                      ),
    .valid_o(spatz_req_valid                                ),
    .ready_i(spatz_req_ready                                )
  );
  // Add these register declarations at the top of your VFU module
  ///////////////
  //  Control  //
  ///////////////

  // Vector length counter
  vlen_t vl_q, vl_d;
  `FF(vl_q, vl_d, '0)

  // Are we busy?
  logic busy_q, busy_d;
  `FF(busy_q, busy_d, 1'b0)

  // Number of elements in one VRF word
  logic [$clog2(N_FU*(ELEN/8)):0] nr_elem_word;
  assign nr_elem_word = (N_FU * (1 << (MAXEW - spatz_req.vtype.vsew))) >> spatz_req.op_arith.is_narrowing;

  // Functional unit states
  typedef enum logic [1:0] {
    VFU_RunningIPU, 
    VFU_RunningFPU,
    VFU_RunningDIMC //New state for DIMC operations
  } state_t;
  state_t state_d, state_q;
  `FF(state_q, state_d, VFU_RunningFPU)  

  // Propagate the tags through the functional units
  vfu_tag_t ipu_result_tag, fpu_result_tag, dimc_result_tag, result_tag; //DIMC result tag
  vfu_tag_t input_tag;

/*
  assign result_tag = (state_q == VFU_RunningIPU) ? ipu_result_tag :
                      (state_q == VFU_RunningFPU) ? fpu_result_tag :
                      dimc_result_tag; // Propagate the tags for DIMC
*/

  // Number of words advanced by vstart
  vlen_t vstart;
  assign vstart = ((spatz_req.vstart / N_FU) >> (MAXEW - spatz_req.vtype.vsew)) << (MAXEW - spatz_req.vtype.vsew);

  // Should we stall?
  logic stall;
   
  // Do we have the reduction operand?
  logic reduction_operand_ready_d, reduction_operand_ready_q;

  // Are the VFU operands ready?
  logic op1_is_ready, op2_is_ready, op3_is_ready, operands_ready;
  assign op1_is_ready   = spatz_req_valid && ((!spatz_req.op_arith.is_reduction && (!spatz_req.use_vs1 || vrf_rvalid_i[1])) || (spatz_req.op_arith.is_reduction && reduction_operand_ready_q));
  assign op2_is_ready   = spatz_req_valid && ((!spatz_req.use_vs2 || vrf_rvalid_i[0]) || spatz_req.op_arith.is_reduction);
  assign op3_is_ready   = spatz_req_valid && (!spatz_req.vd_is_src || vrf_rvalid_i[2]);
  assign operands_ready = op1_is_ready && op2_is_ready && op3_is_ready && (!spatz_req.op_arith.is_scalar || vfu_rsp_ready_i) && !stall;

  // Valid operations
  logic [N_FU*ELENB-1:0] valid_operations;
  assign valid_operations = (spatz_req.op_arith.is_scalar || spatz_req.op_arith.is_reduction) ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;

  // Pending results
  logic [N_FU*ELENB-1:0] pending_results;
  assign pending_results = result_tag.wb ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;

  // Did we issue a microoperation?
  logic word_issued;

  // Currently running instructions
  logic [NrParallelInstructions-1:0] running_d, running_q;
  `FF(running_q, running_d, '0)

  // Instruction type detection
  logic is_fpu_insn;
  logic is_dimc_insn;
  assign is_fpu_insn = FPU && spatz_req.op inside {[VFADD:VSDOTP]};
  assign is_dimc_insn = (spatz_req.op == DIMC_OP);  // New DIMC opcode

  // Functional unit busy signals
  logic is_fpu_busy; 
  logic is_ipu_busy;
  logic is_dimc_busy; //DIMC

  // Scalar results (sent back to Snitch)
  elen_t scalar_result;

  // Is this the last request?
  logic last_request;

  // Reduction state
  typedef enum logic [2:0] {
    Reduction_NormalExecution,
    Reduction_Wait,
    Reduction_Init,
    Reduction_Reduce,
    Reduction_WriteBack
   } reduction_state_t;
   reduction_state_t reduction_state_d, reduction_state_q;
  `FF(reduction_state_q, reduction_state_d, Reduction_NormalExecution)

  // Is the reduction done?
  logic reduction_done;

  //DIMC PSOUT INDEX TRACK
  logic [2:0] current_element_idx;
  
  // Are we producing the upper or lower part of the results  of a narrowing instruction?
  logic narrowing_upper_d, narrowing_upper_q;
  `FF(narrowing_upper_q, narrowing_upper_d, 1'b0)

  // Are we reading the upper or lower part of the operands of a widening instruction?
  logic widening_upper_d, widening_upper_q;
  `FF(widening_upper_q, widening_upper_d, 1'b0)

  // Are any results valid?
  logic [N_FU*ELEN-1:0]  result;
  logic [N_FU*ELENB-1:0] result_valid;
  logic                  result_ready;

  always_comb begin: control_proc
    // Maintain state
    vl_d              = vl_q;
    busy_d            = busy_q;
    running_d         = running_q;
    state_d           = state_q;
    narrowing_upper_d = narrowing_upper_q;
    widening_upper_d  = widening_upper_q;

    // We are not stalling
    stall = 1'b0;

    // This is not the last request
    last_request = 1'b0;

    // We are handling an instruction
    spatz_req_ready = 1'b0;

    // Do not ack anything
    vfu_rsp_valid_o = 1'b0;
    vfu_rsp_o       = '0;

    // Change number of remaining elements
    if (word_issued) begin
      vl_d              = vl_q + nr_elem_word;
      // Update narrowing information
      narrowing_upper_d = narrowing_upper_q ^ spatz_req.op_arith.is_narrowing;
      widening_upper_d  = widening_upper_q ^ (spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2);
    end

    // Current state of the VFU
    if (spatz_req_valid) begin
      unique case (state_q)
        VFU_RunningIPU: begin
          if (is_fpu_insn) begin // Keep IPU->FPU transition
            if (is_ipu_busy)begin
              stall = 1'b1;
            end
            else begin
              state_d = VFU_RunningFPU;
              stall   = 1'b1;
            end
          end
          else if (is_dimc_insn) begin // Add DIMC request handling
            if (is_ipu_busy)
              stall = 1'b1;
            else begin
              state_d = VFU_RunningDIMC;
              stall   = 1'b1;
            end
          end
        end
        
        VFU_RunningFPU: begin
          if (is_dimc_insn) begin // Add DIMC request handling
            if (is_fpu_busy)
              stall = 1'b1;
            else begin
              state_d = VFU_RunningDIMC;
              stall   = 1'b1;
            end
          end
          else if (!is_fpu_insn) begin // Keep FPU->IPU transition
            if (is_fpu_busy)
              stall = 1'b1;
            else begin
              state_d = VFU_RunningIPU;
              stall   = 1'b1;
            end
          end
        end
        
        VFU_RunningDIMC: begin // New DIMC state 
          if (!is_dimc_insn) begin
            if (is_dimc_busy)
              stall = 1'b1;
            else begin
              state_d = is_fpu_insn ? VFU_RunningFPU : VFU_RunningIPU;
              stall   = 1'b1;
            end
          end else begin
            // Handle back-to-back DIMC instructions
              if (is_dimc_busy) begin
                stall = 1'b1;  // Wait if DIMC is still busy
              end else begin
              // Ready for next DIMC instruction
              spatz_req_ready = 1'b1;  // Accept new instruction
              // ADD THIS CRITICAL LINE: Reset state for new instruction
              // When current DIMC instruction is done and we accept new one,
              // we need to "re-enter" the DIMC state
              state_d = VFU_RunningDIMC;  // This ensures fresh state entry
            end  
          end
        end
        
        default:;
      endcase
    end

      // Finished the execution!
  if (spatz_req_valid && 
      (((vl_d >= spatz_req.vl && !spatz_req.op_arith.is_reduction) || reduction_done) ||
       (is_dimc_insn && (spatz_req.op_cfg.dimc.cmd inside {DIMC_CMD_LD_F, DIMC_CMD_LD_K} || !is_dimc_busy)))) begin
    spatz_req_ready         = spatz_req_valid;
    busy_d                  = 1'b0;
    vl_d                    = '0;
    last_request            = 1'b1;
    running_d[spatz_req.id] = 1'b0;
    widening_upper_d        = 1'b0;
    narrowing_upper_d       = 1'b0;
  end
  // Do we have a new instruction?
  else if (spatz_req_valid && !running_d[spatz_req.id]) begin
    // Start at vstart
    vl_d                    = vstart;
    busy_d                  = 1'b1;
    running_d[spatz_req.id] = 1'b1;

    // Change number of remaining elements
    if (word_issued)
      vl_d = vl_q + nr_elem_word;
  end

  // An instruction finished execution
  if ((result_tag.last && &(result_valid | ~pending_results) && reduction_state_q inside {Reduction_NormalExecution, Reduction_Wait}) || 
      reduction_done ||
      (is_dimc_insn && (spatz_req.op_cfg.dimc.cmd inside {DIMC_CMD_LD_F, DIMC_CMD_LD_K} || !is_dimc_busy))) begin
    vfu_rsp_o.id      = result_tag.id;
    vfu_rsp_o.rd      = result_tag.vd_addr[GPRWidth-1:0];
    vfu_rsp_o.wb      = result_tag.wb;
    vfu_rsp_o.result  = result_tag.wb ? scalar_result : '0;
    vfu_rsp_valid_o   = 1'b1;
  end
    

  end: control_proc

 // ========== SEPARATE DEBUG BLOCKS ==========
 /*
 // Add debug prints
 always @(posedge clk_i) begin
  if (state_q == VFU_RunningDIMC) begin
    $display("[DIMC WRITE] Time %t: element_sel=%0d, wbe=%08h, data[%0d]=0x%08h",
              $time, 
              dimc_element_sel, 
              vreg_wbe,
              dimc_element_sel,
              dimc_32bit_result);
  end
 end
 */
 // ========== CONTINUE WITH EXISTING CODE ==========


  //////////////
  // Operands //
  //////////////

  // Reduction registers
  elen_t [1:0] reduction_q, reduction_d;
  `FFL(reduction_q, reduction_d, reduction_operand_ready_d, '0)

  // IPU results
  logic [N_FU*ELEN-1:0]  ipu_result;
  logic [N_FU*ELENB-1:0] ipu_result_valid;
  logic [N_FU*ELENB-1:0] ipu_in_ready;

  // FPU results
  logic [N_FU*ELEN-1:0]  fpu_result;
  logic [N_FU*ELENB-1:0] fpu_result_valid;
  logic [N_FU*ELENB-1:0] fpu_in_ready;

  // DIMC results
  logic [N_FU*ELEN-1:0]  dimc_result;
  logic [N_FU*ELENB-1:0] dimc_result_valid;
  logic [N_FU*ELENB-1:0] dimc_in_ready;

  // Operands and result signals
  logic [N_FU*ELEN-1:0]  operand1, operand2, operand3;
  logic [N_FU*ELENB-1:0] in_ready;
  always_comb begin: operand_proc
    if (spatz_req.op_arith.is_scalar)
      operand1 = {1*N_FU{spatz_req.rs1}};
    else if (spatz_req.use_vs1)
      operand1 = spatz_req.op_arith.is_reduction ? $unsigned(reduction_q[1]) : vrf_rdata_i[1];
    else begin
      // Replicate scalar operands
      unique case (spatz_req.op == VSDOTP ? vew_e'(spatz_req.vtype.vsew + 1) : spatz_req.vtype.vsew)
        EW_8 : operand1   = MAXEW == EW_32 ? {4*N_FU{spatz_req.rs1[7:0]}}  : {8*N_FU{spatz_req.rs1[7:0]}};
        EW_16: operand1   = MAXEW == EW_32 ? {2*N_FU{spatz_req.rs1[15:0]}} : {4*N_FU{spatz_req.rs1[15:0]}};
        EW_32: operand1   = MAXEW == EW_32 ? {1*N_FU{spatz_req.rs1[31:0]}} : {2*N_FU{spatz_req.rs1[31:0]}};
        default: operand1 = {1*N_FU{spatz_req.rs1}};
      endcase
    end

    if ((!spatz_req.op_arith.is_scalar || spatz_req.op == VADD) && spatz_req.use_vs2)
      operand2 = spatz_req.op_arith.is_reduction ? $unsigned(reduction_q[0]) : vrf_rdata_i[0];
    else
      // Replicate scalar operands
      unique case (spatz_req.op == VSDOTP ? vew_e'(spatz_req.vtype.vsew + 1) : spatz_req.vtype.vsew)
        EW_8 : operand2   = MAXEW == EW_32 ? {4*N_FU{spatz_req.rs2[7:0]}}  : {8*N_FU{spatz_req.rs2[7:0]}};
        EW_16: operand2   = MAXEW == EW_32 ? {2*N_FU{spatz_req.rs2[15:0]}} : {4*N_FU{spatz_req.rs2[15:0]}};
        EW_32: operand2   = MAXEW == EW_32 ? {1*N_FU{spatz_req.rs2[31:0]}} : {2*N_FU{spatz_req.rs2[31:0]}};
        default: operand2 = {1*N_FU{spatz_req.rs2}};
      endcase

    operand3 = spatz_req.op_arith.is_scalar ? {1*N_FU{spatz_req.rsd}} : vrf_rdata_i[2];
  end: operand_proc

  //DIMC logic management

  assign in_ready = (state_q == VFU_RunningIPU) ? ipu_in_ready :
                    (state_q == VFU_RunningFPU) ? fpu_in_ready :
                    dimc_in_ready;

  assign result = (state_q == VFU_RunningIPU) ? ipu_result :
                  (state_q == VFU_RunningFPU) ? fpu_result :
                  dimc_result;

  assign result_valid = (state_q == VFU_RunningIPU) ? ipu_result_valid :
                        (state_q == VFU_RunningFPU) ? fpu_result_valid :
                        dimc_result_valid;

  assign scalar_result = result[ELEN-1:0];

  ///////////////////////
  //  Reduction logic  //
  ///////////////////////

  // Reduction pointer
  vlen_t reduction_pointer_d, reduction_pointer_q;
  `FF(reduction_pointer_q, reduction_pointer_d, '0)

  // Are the reduction operands ready?
  `FF(reduction_operand_ready_q, reduction_operand_ready_d, 1'b0)

  // Do we need to request reduction operands?
  logic [1:0] reduction_operand_request;

  always_comb begin: proc_reduction
    // Maintain state
    reduction_state_d   = reduction_state_q;
    reduction_pointer_d = reduction_pointer_q;

    // No operands
    reduction_d               = reduction_q;
    reduction_operand_ready_d = 1'b0;

    // Did we issue a word to the FUs?
    word_issued = 1'b0;

    // Are we ready to accept a result?
    result_ready = 1'b0;

    // Reduction did not finish
    reduction_done = 1'b0;

    // Only request when initializing the reduction register
    reduction_operand_request[0] = (reduction_state_q == Reduction_Init) || !spatz_req.op_arith.is_reduction;
    reduction_operand_request[1] = (reduction_state_q inside {Reduction_Init, Reduction_Reduce}) || !spatz_req.op_arith.is_reduction;

    unique case (reduction_state_q)
      Reduction_NormalExecution: begin
        // Did we issue a word to the FUs?
        word_issued = spatz_req_valid && &(in_ready | ~valid_operations) && operands_ready && !stall;

        // Are we ready to accept a result?
        result_ready = &(result_valid | ~pending_results) && ((result_tag.wb && vfu_rsp_ready_i) || vrf_wvalid_i);

        // Initialize the pointers
        reduction_pointer_d = '0;

        // Do we have a new reduction instruction?
        if (spatz_req_valid && !running_q[spatz_req.id] && spatz_req.op_arith.is_reduction)
          reduction_state_d = (is_fpu_busy || is_dimc_busy) ? Reduction_Wait : Reduction_Init;
      end

      Reduction_Wait: begin
        // Are we ready to accept a result?
        result_ready = &(result_valid | ~pending_results) && ((result_tag.wb && vfu_rsp_ready_i) || vrf_wvalid_i);

        if (!is_fpu_busy && !is_dimc_busy)
          reduction_state_d = Reduction_Init;
      end

      Reduction_Init: begin
        // Initialize the reduction
        // verilator lint_off SELRANGE
        unique case (spatz_req.vtype.vsew)
          EW_8 : begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][7:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][8*reduction_pointer_q[idx_width(N_FU*ELENB)-1:0] +: 8]);
          end
          EW_16: begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][15:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][16*reduction_pointer_q[idx_width(N_FU*ELENB)-2:0] +: 16]);
          end
          EW_32: begin
            reduction_d[0] = $unsigned(vrf_rdata_i[0][31:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][32*reduction_pointer_q[idx_width(N_FU*ELENB)-3:0] +: 32]);
          end
          default: begin
          `ifdef MEMPOOL_SPATZ
            reduction_d = '0;
          `else
            if (MAXEW == EW_64) begin
              reduction_d[0] = $unsigned(vrf_rdata_i[0][63:0]);
              reduction_d[1] = $unsigned(vrf_rdata_i[1][64*reduction_pointer_q[idx_width(N_FU*ELENB)-4:0] +: 64]);
            end
          `endif
          end
        endcase
        // verilator lint_on SELRANGE

        if (vrf_rvalid_i[0] && vrf_rvalid_i[1]) begin
          automatic logic [idx_width(N_FU*ELENB)-1:0] pnt;

          reduction_operand_ready_d = 1'b1;
          reduction_pointer_d       = reduction_pointer_q + 1;
          reduction_state_d         = Reduction_Reduce;

          // Request next word
          pnt = reduction_pointer_d << int'(spatz_req.vtype.vsew);
          if (!(|pnt))
            word_issued = 1'b1;
        end
      end

      Reduction_Reduce: begin
        // Forward result
        // verilator lint_off SELRANGE
        unique case (spatz_req.vtype.vsew)
          EW_8 : begin
            reduction_d[0] = $unsigned(result[7:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][8*reduction_pointer_q[idx_width(N_FU*ELENB)-1:0] +: 8]);
          end
          EW_16: begin
            reduction_d[0] = $unsigned(result[15:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][16*reduction_pointer_q[idx_width(N_FU*ELENB)-2:0] +: 16]);
          end
          EW_32: begin
            reduction_d[0] = $unsigned(result[31:0]);
            reduction_d[1] = $unsigned(vrf_rdata_i[1][32*reduction_pointer_q[idx_width(N_FU*ELENB)-3:0] +: 32]);
          end
          default: begin
          `ifdef MEMPOOL_SPATZ
            reduction_d = '0;
          `else
            if (MAXEW == EW_64) begin
              reduction_d[0] = $unsigned(result[63:0]);
              reduction_d[1] = $unsigned(vrf_rdata_i[1][64*reduction_pointer_q[idx_width(N_FU*ELENB)-4:0] +: 64]);
            end
          `endif
          end
        endcase
        // verilator lint_on SELRANGE

        // Got a result!
        if (result_valid[0]) begin
          // Did we get an operand?
          if (vrf_rvalid_i[1]) begin
            automatic logic [idx_width(N_FU*ELENB)-1:0] pnt;

            // Bump pointer
            reduction_pointer_d = reduction_pointer_q + 1;

            // Acknowledge result
            result_ready = 1'b1;

            // Trigger a request
            reduction_operand_ready_d = 1'b1;

            // Request next word
            pnt = reduction_pointer_d << int'(spatz_req.vtype.vsew);
            if (!(|pnt))
              word_issued = 1'b1;
          end
        end

        // Are we done?
        if (reduction_pointer_q == spatz_req.vl) begin
          reduction_state_d         = Reduction_WriteBack;
          result_ready              = 1'b0;
          reduction_operand_ready_d = 1'b0;
        end
      end

      Reduction_WriteBack: begin
        // Acknowledge result
        if (vrf_wvalid_i) begin
          result_ready = 1'b1;

          // We are done with the reduction
          reduction_state_d = Reduction_NormalExecution;

          // Finish the reduction
          reduction_done = 1'b1;
        end
      end

      default;
    endcase
  end: proc_reduction

  ///////////////////////
  // Operand Requester //
  ///////////////////////

  vrf_be_t       vreg_wbe;
  logic          vreg_we;
  logic    [2:0] vreg_r_req;

  // Address register
  vrf_addr_t [2:0] vreg_addr_q, vreg_addr_d;
  `FF(vreg_addr_q, vreg_addr_d, '0)

  // Calculate new vector register address
  always_comb begin : vreg_addr_proc
    vreg_addr_d = vreg_addr_q;

    vrf_raddr_o = vreg_addr_d;
    vrf_waddr_o = result_tag.vd_addr;

    // Tag (propagated with the operations)
    input_tag = '{
      id             : spatz_req.id,
      vsew           : spatz_req.vtype.vsew,
      vstart         : spatz_req.vstart,
      vd_addr        : spatz_req.op_arith.is_scalar ? vrf_addr_t'(spatz_req.rd) : vreg_addr_q[2],
      wb             : spatz_req.op_arith.is_scalar,
      last           : last_request,
      narrowing      : spatz_req.op_arith.is_narrowing,
      narrowing_upper: narrowing_upper_q,
      reduction      : spatz_req.op_arith.is_reduction
    };

    if (spatz_req_valid && vl_q == '0) begin
      vreg_addr_d[0] = (spatz_req.vs2 + vstart) << $clog2(NrWordsPerVector);
      vreg_addr_d[1] = (spatz_req.vs1 + vstart) << $clog2(NrWordsPerVector);
      vreg_addr_d[2] = (spatz_req.vd + vstart) << $clog2(NrWordsPerVector);

      // Direct feedthrough
      vrf_raddr_o = vreg_addr_d;
      if (!spatz_req.op_arith.is_scalar)
        input_tag.vd_addr = vreg_addr_d[2];

      // Did we commit a word already?
      if (word_issued) begin
        vreg_addr_d[0] = vreg_addr_d[0] + (!spatz_req.op_arith.widen_vs2 || widening_upper_q);
        vreg_addr_d[1] = vreg_addr_d[1] + (!spatz_req.op_arith.widen_vs1 || widening_upper_q);
        vreg_addr_d[2] = vreg_addr_d[2] + (!spatz_req.op_arith.is_reduction && (!spatz_req.op_arith.is_narrowing || narrowing_upper_q));
      end
    end else if (spatz_req_valid && vl_q < spatz_req.vl && word_issued) begin
      vreg_addr_d[0] = vreg_addr_q[0] + (!spatz_req.op_arith.widen_vs2 || widening_upper_q);
      vreg_addr_d[1] = vreg_addr_q[1] + (!spatz_req.op_arith.widen_vs1 || widening_upper_q);
      vreg_addr_d[2] = vreg_addr_q[2] + (!spatz_req.op_arith.is_reduction && (!spatz_req.op_arith.is_narrowing || narrowing_upper_q));
    end
  end: vreg_addr_proc

  always_comb begin : operand_req_proc
    vreg_r_req = '0;
    vreg_we    = '0;
    vreg_wbe   = '0;

    if (spatz_req_valid && vl_q < spatz_req.vl)
      // Request operands
      vreg_r_req = {spatz_req.vd_is_src, spatz_req.use_vs1 && reduction_operand_request[1], spatz_req.use_vs2 && reduction_operand_request[0]};

    // Got a new result
    if (&(result_valid | ~pending_results) && !result_tag.reduction) begin
      vreg_we  = !result_tag.wb;
     
      // ========== DIMC SPECIFIC LOGIC ==========
      if (state_q == VFU_RunningDIMC && is_dimc_insn) begin
        // For DIMC: generate byte enables based on element_sel field
        vreg_wbe = '0; // Start with all bytes disabled
      
        // Enable only the 4 bytes for the selected 32-bit element
        // current_element_idx selects which of the 8 elements (0-7) to write
        if (current_element_idx < 8) begin  // Safety check
          // Set 4 bits (32 bits = 4 bytes) at the calculated position
          vreg_wbe[current_element_idx * 4 +: 4] = 4'b1111;
        end
      
        // Debug output
        $display("[DIMC] Writing to element %0d, wbe=0x%h", 
                  current_element_idx, vreg_wbe);
      end 
      // ========== EXISTING LOGIC ==========
      else if (result_tag.narrowing) begin
        // Only write half of the elements
        vreg_wbe = result_tag.narrowing_upper ? {{(N_FU*ELENB/2){1'b1}}, {(N_FU*ELENB/2){1'b0}}} : {{(N_FU*ELENB/2){1'b0}}, {(N_FU*ELENB/2){1'b1}}};
      end
      else begin
       // Default: write all bytes
       vreg_wbe = '1;
      end
    end

    // Reduction finished execution
    if (reduction_state_q == Reduction_WriteBack && result_valid[0]) begin
      vreg_we = 1'b1;
      unique case (spatz_req.vtype.vsew)
        EW_8 : vreg_wbe = 1'h1;
        EW_16: vreg_wbe = 2'h3;
        EW_32: vreg_wbe = 4'hf;
        default: if (MAXEW == EW_64) vreg_wbe = 8'hff;
      endcase
    end
  end : operand_req_proc

  logic [N_FU*ELEN-1:0] vreg_wdata;
  always_comb begin: align_result
    vreg_wdata = result;

    // Realign results
    if (result_tag.narrowing) begin
      unique case (MAXEW)
        EW_64: begin
          if (RVD)
            for (int element = 0; element < N_FU; element++)
              vreg_wdata[32*element + (N_FU * ELEN * result_tag.narrowing_upper / 2) +: 32] = result[64*element +: 32];
        end
        EW_32: begin
          for (int element = 0; element < (MAXEW == EW_64 ? N_FU*2 : N_FU); element++)
            vreg_wdata[16*element + (N_FU * ELEN * result_tag.narrowing_upper / 2) +: 16] = result[32*element +: 16];
        end
        default:;
      endcase
    end
  end

  // Register file signals
  assign vrf_re_o    = vreg_r_req;
  assign vrf_we_o    = vreg_we;
  assign vrf_wbe_o   = vreg_wbe;
  assign vrf_wdata_o = vreg_wdata;
  assign vrf_id_o    = {result_tag.id, {3{spatz_req.id}}};

  //////////
  // IPUs //
  //////////

  // If there are fewer IPUs than FPUs, pipeline the execution of the integer instructions
  logic     [N_IPU*ELENB-1:0] int_ipu_in_ready;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand1;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand2;
  logic     [N_IPU*ELEN-1:0]  int_ipu_operand3;
  logic     [N_IPU*ELEN-1:0]  int_ipu_result;
  vfu_tag_t [N_IPU-1:0]       int_ipu_result_tag;
  logic     [N_IPU*ELENB-1:0] int_ipu_result_valid;
  logic                       int_ipu_result_ready;
  logic     [N_IPU-1:0]       int_ipu_busy;

  assign is_ipu_busy = |int_ipu_busy;

  logic [N_FU*ELEN-1:0] ipu_wide_operand1, ipu_wide_operand2, ipu_wide_operand3;
  always_comb begin: gen_ipu_widening
    automatic logic [N_FU*ELEN/2-1:0] shift_operand1 = !widening_upper_q ? operand1[N_FU*ELEN/2-1:0] : operand1[N_FU*ELEN-1:N_FU*ELEN/2];
    automatic logic [N_FU*ELEN/2-1:0] shift_operand2 = !widening_upper_q ? operand2[N_FU*ELEN/2-1:0] : operand2[N_FU*ELEN-1:N_FU*ELEN/2];

    ipu_wide_operand1 = operand1;
    ipu_wide_operand2 = operand2;
    ipu_wide_operand3 = operand3;

    case (spatz_req.vtype.vsew)
      EW_32: begin
        for (int el = 0; el < N_FU; el++) begin
          if (spatz_req.op_arith.widen_vs1 && MAXEW == EW_64)
            ipu_wide_operand1[64*el +: 64] = spatz_req.op_arith.signed_vs1 ? {{32{shift_operand1[32*el+31]}}, shift_operand1[32*el +: 32]} : {32'b0, shift_operand1[32*el +: 32]};

          if (spatz_req.op_arith.widen_vs2 && MAXEW == EW_64)
            ipu_wide_operand2[64*el +: 64] = spatz_req.op_arith.signed_vs2 ? {{32{shift_operand2[32*el+31]}}, shift_operand2[32*el +: 32]} : {32'b0, shift_operand2[32*el +: 32]};
        end
      end
      EW_16: begin
        for (int el = 0; el < (MAXEW == EW_64 ? 2*N_FU : N_FU); el++) begin
          if (spatz_req.op_arith.widen_vs1)
            ipu_wide_operand1[32*el +: 32] = spatz_req.op_arith.signed_vs1 ? {{16{shift_operand1[16*el+15]}}, shift_operand1[16*el +: 16]} : {16'b0, shift_operand1[16*el +: 16]};

          if (spatz_req.op_arith.widen_vs2)
            ipu_wide_operand2[32*el +: 32] = spatz_req.op_arith.signed_vs2 ? {{16{shift_operand2[16*el+15]}}, shift_operand2[16*el +: 16]} : {16'b0, shift_operand2[16*el +: 16]};
        end
      end
      EW_8: begin
        for (int el = 0; el < (MAXEW == EW_64 ? 4*N_FU : 2*N_FU); el++) begin
          if (spatz_req.op_arith.widen_vs1)
            ipu_wide_operand1[16*el +: 16] = spatz_req.op_arith.signed_vs1 ? {{8{shift_operand1[8*el+7]}}, shift_operand1[8*el +: 8]} : {8'b0, shift_operand1[8*el +: 8]};

          if (spatz_req.op_arith.widen_vs2)
            ipu_wide_operand2[16*el +: 16] = spatz_req.op_arith.signed_vs2 ? {{8{shift_operand2[8*el+7]}}, shift_operand2[8*el +: 8]} : {8'b0, shift_operand2[8*el +: 8]};
        end
      end
      default:;
    endcase
  end: gen_ipu_widening

  if (N_IPU < N_FU) begin: gen_pipeline_ipu
    logic [N_FU*ELEN-1:0] ipu_result_d, ipu_result_q;
    logic [N_FU*ELENB-1:0] ipu_result_valid_q, ipu_result_valid_d;
    logic [idx_width(N_FU/N_IPU)-1:0] ipu_result_pnt_d, ipu_result_pnt_q;
    vfu_tag_t ipu_result_tag_d, ipu_result_tag_q;
    logic [idx_width(N_FU/N_IPU)-1:0] ipu_operand_pnt_d, ipu_operand_pnt_q;

    `FF(ipu_result_q, ipu_result_d, '0)
    `FF(ipu_result_valid_q, ipu_result_valid_d, '0)
    `FF(ipu_result_pnt_q, ipu_result_pnt_d, '0)
    `FF(ipu_result_tag_q, ipu_result_tag_d, '0)
    `FF(ipu_operand_pnt_q, ipu_operand_pnt_d, '0)

    always_comb begin
      // Maintain state
      ipu_result_d       = ipu_result_q;
      ipu_result_valid_d = ipu_result_valid_q;
      ipu_result_pnt_d   = ipu_result_pnt_q;
      ipu_operand_pnt_d  = ipu_operand_pnt_q;
      ipu_result_tag_d   = ipu_result_tag_q;

      // Send operands
      ipu_in_ready     = 1'b0;  
      int_ipu_operand1 = ipu_wide_operand1[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      int_ipu_operand2 = ipu_wide_operand2[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      int_ipu_operand3 = ipu_wide_operand3[ipu_operand_pnt_q*ELEN*N_IPU +: ELEN*N_IPU];
      if (spatz_req_valid && operands_ready && &int_ipu_in_ready && !is_fpu_insn) begin
        ipu_operand_pnt_d = ipu_operand_pnt_q + 1;
        if (ipu_operand_pnt_d == '0 || !(&valid_operations[ipu_operand_pnt_d*ELENB*N_IPU +: ELENB*N_IPU]))
          ipu_operand_pnt_d = '0;

        // Issued all elements
        if (ipu_operand_pnt_d == 0)
          ipu_in_ready = '1;
      end

      // Clean-up results
      if (result_ready) begin
        ipu_result_d       = '0;
        ipu_result_valid_d = '0;
        ipu_result_tag_d   = '0;
      end

      // Store results
      int_ipu_result_ready = '0;
      if (&int_ipu_result_valid) begin
        ipu_result_d[ipu_result_pnt_q*ELEN*N_IPU +: ELEN*N_IPU]         = int_ipu_result;
        ipu_result_valid_d[ipu_result_pnt_q*ELENB*N_IPU +: ELENB*N_IPU] = int_ipu_result_valid;
        ipu_result_tag_d                                                = int_ipu_result_tag[0];
        ipu_result_pnt_d                                                = ipu_result_pnt_q + 1;
        int_ipu_result_ready                                            = 1'b1;

        // Scalar operation
        if (ipu_result_tag_d.wb || spatz_req.op_arith.is_reduction)
          ipu_result_pnt_d = '0;
      end
    end

    // Forward results
    assign ipu_result       = ipu_result_q;
    assign ipu_result_valid = ipu_result_valid_q;
    assign ipu_result_tag   = ipu_result_tag_q;
  end: gen_pipeline_ipu else begin: gen_no_pipeline_ipu
    assign ipu_in_ready         = int_ipu_in_ready;
    assign int_ipu_operand1     = ipu_wide_operand1;
    assign int_ipu_operand2     = ipu_wide_operand2;
    assign int_ipu_operand3     = ipu_wide_operand3;
    assign ipu_result           = int_ipu_result;
    assign ipu_result_valid     = int_ipu_result_valid;
    assign int_ipu_result_ready = result_ready;
    assign ipu_result_tag       = int_ipu_result_tag[0];
  end

  for (genvar ipu = 0; unsigned'(ipu) < N_IPU; ipu++) begin : gen_ipus
    logic ipu_ready;
    assign int_ipu_in_ready[ipu*ELENB +: ELENB] = {ELENB{ipu_ready}};
 
    logic is_widening;
    assign is_widening = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2;

    vew_e sew;
    assign sew = vew_e'(int'(spatz_req.vtype.vsew) + is_widening);

    spatz_ipu #(
      .tag_t(vfu_tag_t)
    ) i_ipu (
      .clk_i            (clk_i                                                                                           ),
      .rst_ni           (rst_ni                                                                                          ),
      .operation_i      (spatz_req.op                                                                                    ),
      // Only the IPU0 executes scalar instructions
      .operation_valid_i(spatz_req_valid && operands_ready && (!spatz_req.op_arith.is_scalar || ipu == 0) && !is_fpu_insn),
      .operation_ready_o(ipu_ready                                                                                       ),
      .op_s1_i          (int_ipu_operand1[ipu*ELEN +: ELEN]                                                              ),
      .op_s2_i          (int_ipu_operand2[ipu*ELEN +: ELEN]                                                              ),
      .op_d_i           (int_ipu_operand3[ipu*ELEN +: ELEN]                                                              ),
      .tag_i            (input_tag                                                                                       ),
      .carry_i          ('0                                                                                              ),
      .sew_i            (sew                                                                                             ),
      .be_o             (/* Unused */                                                                                    ),
      .result_o         (int_ipu_result[ipu*ELEN +: ELEN]                                                                ),
      .result_valid_o   (int_ipu_result_valid[ipu*ELENB +: ELENB]                                                        ),
      .result_ready_i   (int_ipu_result_ready                                                                            ),
      .tag_o            (int_ipu_result_tag[ipu]                                                                         ),
      .busy_o           (int_ipu_busy[ipu]                                                                               )
    );   
  end : gen_ipus

  ////////////
  //  FPUs  //
  ////////////

  if (FPU) begin: gen_fpu
    operation_e fpu_op;
    fp_format_e fpu_src_fmt, fpu_dst_fmt;
    int_format_e fpu_int_fmt;
    logic fpu_op_mode;
    logic fpu_vectorial_op;

    logic [N_FPU-1:0] fpu_busy_d, fpu_busy_q;
    `FF(fpu_busy_q, fpu_busy_d, '0)

    status_t [N_FPU-1:0] fpu_status_d, fpu_status_q;
    `FF(fpu_status_q, fpu_status_d, '0)

    always_comb begin: gen_decoder
      fpu_op           = fpnew_pkg::FMADD;
      fpu_op_mode      = 1'b0;
      fpu_vectorial_op = 1'b0;
      is_fpu_busy      = |fpu_busy_q;
      fpu_src_fmt      = fpnew_pkg::FP32;
      fpu_dst_fmt      = fpnew_pkg::FP32;
      fpu_int_fmt      = fpnew_pkg::INT32;

      fpu_status_o = '0;
      for (int fpu = 0; fpu < N_FPU; fpu++)
        fpu_status_o |= fpu_status_q[fpu];

      if (FPU) begin
        unique case (spatz_req.vtype.vsew)
          EW_64: begin
            if (RVD) begin
              fpu_src_fmt = fpnew_pkg::FP64;
              fpu_dst_fmt = fpnew_pkg::FP64;
              fpu_int_fmt = fpnew_pkg::INT64;
            end
          end
          EW_32: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? fpnew_pkg::FP64 : fpnew_pkg::FP32;
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP ? fpnew_pkg::FP64          : fpnew_pkg::FP32;
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F} ? fpnew_pkg::INT64                            : fpnew_pkg::INT32;
            fpu_vectorial_op = FLEN > 32;
          end
          EW_16: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? fpnew_pkg::FP32 : (spatz_req.fm.src ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16);
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP          ? fpnew_pkg::FP32 : (spatz_req.fm.dst ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16);
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F}                             ? fpnew_pkg::INT32 : fpnew_pkg::INT16;
            fpu_vectorial_op = 1'b1;
          end
          EW_8: begin
            fpu_src_fmt      = spatz_req.op_arith.is_narrowing || spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 ? (spatz_req.fm.src ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16) : (spatz_req.fm.src ? fpnew_pkg::FP8ALT : fpnew_pkg::FP8);
            fpu_dst_fmt      = spatz_req.op_arith.widen_vs1 || spatz_req.op_arith.widen_vs2 || spatz_req.op == VSDOTP          ? (spatz_req.fm.dst ? fpnew_pkg::FP16ALT : fpnew_pkg::FP16) : (spatz_req.fm.dst ? fpnew_pkg::FP8ALT : fpnew_pkg::FP8);
            fpu_int_fmt      = spatz_req.op_arith.is_narrowing && spatz_req.op inside {VI2F, VU2F}                             ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
            fpu_vectorial_op = 1'b1;
          end
          default:;
        endcase

        unique case (spatz_req.op)
          VFADD: fpu_op = fpnew_pkg::ADD;
          VFSUB: begin
            fpu_op      = fpnew_pkg::ADD;
            fpu_op_mode = 1'b1;
          end
          VFMUL  : fpu_op = fpnew_pkg::MUL;
          VFMADD : fpu_op = fpnew_pkg::FMADD;
          VFMSUB : begin
            fpu_op      = fpnew_pkg::FMADD;
            fpu_op_mode = 1'b1;
          end
          VFNMSUB: fpu_op = fpnew_pkg::FNMSUB;
          VFNMADD: begin
            fpu_op      = fpnew_pkg::FNMSUB;
            fpu_op_mode = 1'b1;
          end

          VFMINMAX: begin
            fpu_op = fpnew_pkg::MINMAX;
            fpu_dst_fmt = fpu_src_fmt;
          end


          VFSGNJ : begin
            fpu_op = fpnew_pkg::SGNJ;
            fpu_dst_fmt = fpu_src_fmt;
          end
          VFCLASS: begin
            fpu_op = fpnew_pkg::CLASSIFY;
            fpu_dst_fmt = fpu_src_fmt;
          end
          VFCMP  : begin
            fpu_op = fpnew_pkg::CMP;
            fpu_dst_fmt = fpu_src_fmt;
          end

          VF2F: fpu_op = fpnew_pkg::F2F;
          VF2I: fpu_op = fpnew_pkg::F2I;
          VF2U: begin
            fpu_op      = fpnew_pkg::F2I;
            fpu_op_mode = 1'b1;
          end
          VI2F: fpu_op = fpnew_pkg::I2F;
          VU2F: begin
            fpu_op      = fpnew_pkg::I2F;
            fpu_op_mode = 1'b1;
          end

          VSDOTP: fpu_op = fpnew_pkg::SDOTP;

          default:;
        endcase
      end
    end: gen_decoder

    logic [N_FPU*ELEN-1:0] wide_operand1, wide_operand2, wide_operand3;
    always_comb begin: gen_widening
      automatic logic [N_FPU*ELEN/2-1:0] shift_operand1 = !widening_upper_q ? operand1[N_FPU*ELEN/2-1:0] : operand1[N_FPU*ELEN-1:N_FPU*ELEN/2];
      automatic logic [N_FPU*ELEN/2-1:0] shift_operand2 = !widening_upper_q ? operand2[N_FPU*ELEN/2-1:0] : operand2[N_FPU*ELEN-1:N_FPU*ELEN/2];

      wide_operand1 = operand1;
      wide_operand2 = operand2;
      wide_operand3 = operand3;

      case (spatz_req.vtype.vsew)
        EW_32: begin
          for (int el = 0; el < N_FPU; el++) begin
            if (spatz_req.op_arith.widen_vs1 && MAXEW == EW_64)
              wide_operand1[64*el +: 64] = widen_fp32_to_fp64(shift_operand1[32*el +: 32]);

            if (spatz_req.op_arith.widen_vs2 && MAXEW == EW_64)
              wide_operand2[64*el +: 64] = widen_fp32_to_fp64(shift_operand2[32*el +: 32]);
          end
        end
        EW_16: begin
          for (int el = 0; el < (MAXEW == EW_64 ? 2*N_FPU : N_FPU); el++) begin
            if (spatz_req.op_arith.widen_vs1)
              wide_operand1[32*el +: 32] = widen_fp16_to_fp32(shift_operand1[16*el +: 16]);

            if (spatz_req.op_arith.widen_vs2)
              wide_operand2[32*el +: 32] = widen_fp16_to_fp32(shift_operand2[16*el +: 16]);
          end
        end
        EW_8: begin
          for (int el = 0; el < (MAXEW == EW_64 ? 4*N_FPU : 2*N_FPU); el++) begin
            if (spatz_req.op_arith.widen_vs1)
              wide_operand1[16*el +: 16] = widen_fp8_to_fp16(shift_operand1[8*el +: 8]);

            if (spatz_req.op_arith.widen_vs2)
              wide_operand2[16*el +: 16] = widen_fp8_to_fp16(shift_operand2[8*el +: 8]);
          end
        end
        default:;
      endcase
    end: gen_widening

    for (genvar fpu = 0; unsigned'(fpu) < N_FPU; fpu++) begin : gen_fpnew
      logic int_fpu_result_valid;
      logic int_fpu_in_ready;
      vfu_tag_t tag;

      assign fpu_in_ready[fpu*ELENB +: ELENB]     = {ELENB{int_fpu_in_ready}};
      assign fpu_result_valid[fpu*ELENB +: ELENB] = {ELENB{int_fpu_result_valid}};

      elen_t fpu_operand1, fpu_operand2, fpu_operand3;
      assign fpu_operand1 = spatz_req.op_arith.switch_rs1_rd ? wide_operand3[fpu*ELEN +: ELEN] : wide_operand1[fpu*ELEN +: ELEN];
      assign fpu_operand2 = wide_operand2[fpu*ELEN +: ELEN];
      assign fpu_operand3 = (fpu_op == fpnew_pkg::ADD || spatz_req.op_arith.switch_rs1_rd) ? wide_operand1[fpu*ELEN +: ELEN] : wide_operand3[fpu*ELEN +: ELEN];

      logic int_fpu_in_valid;
      assign int_fpu_in_valid = spatz_req_valid && operands_ready && (!spatz_req.op_arith.is_scalar || fpu == 0) && is_fpu_insn;

      // Generate an FPU pipeline
      elen_t fpu_operand1_q, fpu_operand2_q, fpu_operand3_q;
      operation_e fpu_op_q;
      fp_format_e fpu_src_fmt_q, fpu_dst_fmt_q;
      int_format_e fpu_int_fmt_q;
      logic fpu_op_mode_q;
      logic fpu_vectorial_op_q;
      roundmode_e rm_q;
      vfu_tag_t input_tag_q;
      logic fpu_in_valid_q;
      logic fpu_in_ready_d;

      `FFL(fpu_operand1_q, fpu_operand1, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_operand2_q, fpu_operand2, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_operand3_q, fpu_operand3, int_fpu_in_valid && int_fpu_in_ready, '0)
      `FFL(fpu_op_q, fpu_op, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FMADD)
      `FFL(fpu_src_fmt_q, fpu_src_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FP32)
      `FFL(fpu_dst_fmt_q, fpu_dst_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::FP32)
      `FFL(fpu_int_fmt_q, fpu_int_fmt, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::INT8)
      `FFL(fpu_op_mode_q, fpu_op_mode, int_fpu_in_valid && int_fpu_in_ready, 1'b0)
      `FFL(fpu_vectorial_op_q, fpu_vectorial_op, int_fpu_in_valid && int_fpu_in_ready, 1'b0)
      `FFL(rm_q, spatz_req.rm, int_fpu_in_valid && int_fpu_in_ready, fpnew_pkg::RNE)
      `FFL(input_tag_q, input_tag, int_fpu_in_valid && int_fpu_in_ready, '{vsew: EW_8, default: '0})
      `FFL(fpu_in_valid_q, int_fpu_in_valid, int_fpu_in_ready, 1'b0)
      assign int_fpu_in_ready = !fpu_in_valid_q || fpu_in_valid_q && fpu_in_ready_d;

      fpnew_top #(
        .Features                   (FPUFeatures           ),
        .Implementation             (FPUImplementation     ),
        .TagType                    (vfu_tag_t             ),
        .StochasticRndImplementation(fpnew_pkg::DEFAULT_RSR)
      ) i_fpu (
        .clk_i         (clk_i                                                  ),
        .rst_ni        (rst_ni                                                 ),
        .hart_id_i     ({hart_id_i[31-$clog2(N_FPU):0], fpu[$clog2(N_FPU)-1:0]}),
        .flush_i       (1'b0                                                   ),
        .busy_o        (fpu_busy_d[fpu]                                        ),
        .operands_i    ({fpu_operand3_q, fpu_operand2_q, fpu_operand1_q}       ),
        // Only the FPU0 executes scalar instructions
        .in_valid_i    (fpu_in_valid_q                                         ),
        .in_ready_o    (fpu_in_ready_d                                         ),
        .op_i          (fpu_op_q                                               ),
        .src_fmt_i     (fpu_src_fmt_q                                          ),
        .dst_fmt_i     (fpu_dst_fmt_q                                          ),
        .int_fmt_i     (fpu_int_fmt_q                                          ),
        .vectorial_op_i(fpu_vectorial_op_q                                     ),
        .op_mod_i      (fpu_op_mode_q                                          ),
        .tag_i         (input_tag_q                                            ),
        .simd_mask_i   ('1                                                     ),
        .rnd_mode_i    (rm_q                                                   ),
        .result_o      (fpu_result[fpu*ELEN +: ELEN]                           ),
        .out_valid_o   (int_fpu_result_valid                                   ),
        .out_ready_i   (result_ready                                           ),
        .status_o      (fpu_status_d[fpu]                                      ),
        .tag_o         (tag                                                    )
      );

      if (fpu == 0) begin: gen_fpu_tag
        assign fpu_result_tag = tag;
      end: gen_fpu_tag
    end : gen_fpnew
  end: gen_fpu else begin: gen_no_fpu
    assign is_fpu_busy      = 1'b0;
    assign fpu_in_ready     = '0;
    assign fpu_result       = '0;
    assign fpu_result_valid = '0;
    assign fpu_result_tag   = '0;
    assign fpu_status_o     = '0;
  end: gen_no_fpu
 
  ////////////
  //  DIMC  //
  ////////////

  // DIMC signals
  logic        dimc_ready;
  logic [3:0]  dimc_result_4bit;
  logic [23:0] dimc_psout;
  logic        _COMPE;
  logic        _FCSN ;
  logic [1:0]  _MODE ;
  logic [1:0]  _FA   ;
  logic [255:0]_FD   ;
  logic [23:0]_ADDIN ;
  logic [255:0]_Q    ;
  logic [255:0]_D    ;
  logic [7:0]  _RA   ;
  logic [7:0]  _WA   ;
  logic _RCSN ;
  logic _RCSN0;
  logic _RCSN1;
  logic _RCSN2;
  logic _RCSN3;
  logic _WCSN;
  logic _WEN;
  logic [255:0]_M;
  logic [7:0]_MCT;
  logic compute_pulse;
  logic _select_F;
  logic _select_K;
  
  // DIMC element select from instruction
  logic [2:0] dimc_element_sel;
  logic [31:0] dimc_32bit_result;// Create 32-bit result from 24-bit PS output (zero-extend to 32-bit)
  logic [N_FU*ELEN-1:0] dimc_result_wide;// Create 256-bit result with 32-bit element in correct position
 
  // FIFO to track vd for in-flight DIMC computations
  logic [7:0] dimc_vd_fifo [0:3];      // 4-entry FIFO (max 4 in-flight) vd+sel bits [7:5]=element_sel, bits [4:0]=vd
  logic [1:0] dimc_fifo_head;          // Read pointer
  logic [1:0] dimc_fifo_tail;          // Write pointer  
  logic [2:0] dimc_fifo_count;         // Number of entries in FIFO

  // Store tags for each in-flight computation
 vfu_tag_t dimc_tag_fifo [0:3];

 // Combinational tag output
 vfu_tag_t dimc_result_tag_comb;
  
  assign compute_pulse = spatz_req_valid && 
                        ((spatz_req.op_cfg.dimc.cmd == DIMC_CMD_DSS) ||
                         (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_DPS));

  assign _select_F = ~(spatz_req_valid && 
                        (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_LD_F)) ;

  assign _select_K = ~(spatz_req_valid && 
                        (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_LD_K)) ;
  
  // Use read port 0 for DIMC VRF access
  always_comb begin:DIMC_DECODE
    if (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_LD_F) begin: gen_dimc_DL_F
      assign  _COMPE =1'b0;
      assign  _FCSN  =_select_F;
      assign  _MODE  = 2'b00;
      assign  _FA    =spatz_req.op_cfg.dimc.sec;
      assign  _FD    =vrf_rdata_i[1];
      assign  _D     =0;
      assign  _WA    =7'b0;
      assign  _RCSN  =1'b1;
      assign  _RCSN0 =1'b1;
      assign  _RCSN1 =1'b1;
      assign  _RCSN2 =1'b1;
      assign  _RCSN3 =1'b1;
      assign  _WCSN  =1'b1;
      assign  _WEN   =1'b1;
    end: gen_dimc_DL_F
    if (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_LD_K) begin: gen_dimc_DL_K
      assign  _COMPE =1'b0;
      assign  _FCSN  =1'b1;
      assign  _MODE  =2'b00;
      assign  _FA    ='x;
      assign  _FD    ='0;
      assign  _D     =vrf_rdata_i[1];
      assign  _WA    ={spatz_req.op_cfg.dimc.k_row, spatz_req.op_cfg.dimc.sec};
      assign  _RCSN  =1'b1;
      assign  _RCSN0 =1'b1;
      assign  _RCSN1 =1'b1;
      assign  _RCSN2 =1'b1;
      assign  _RCSN3 =1'b1;
      assign  _WCSN  =_select_K;
      assign  _WEN   =_select_K;  
      assign _M      =   '1;  // ? CRITICAL: Enable all bits for writing
      assign _MCT    = 8'h00;  // No masking for kernel load
    end: gen_dimc_DL_K
    if (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_DPS) begin: gen_dimc_DPS
      assign  _COMPE =compute_pulse;
      assign  _FCSN  =1'b1;
      assign  _MODE  =spatz_req.op_cfg.dimc.flags[1:0];
      assign  _FA    ='x;
      assign  _FD    ='x;
      assign  _ADDIN =operand1[23:0];
      assign  _D     =256'b0;
      assign  _RA    ={spatz_req.op_cfg.dimc.k_row, spatz_req.op_cfg.dimc.sec};
      assign  _WA    =7'bxx;
      assign  _RCSN  =1'b0;
      assign  _RCSN0 =1'b0;
      assign  _RCSN1 =1'b0;
      assign  _RCSN2 =1'b0;
      assign  _RCSN3 =1'b0;
      assign  _WCSN  =1'b1;
      assign  _WEN   =1'b1;
    end: gen_dimc_DPS
    if (spatz_req.op_cfg.dimc.cmd == DIMC_CMD_DSS) begin: gen_dimc_DSS
      assign  _COMPE =compute_pulse;
      assign  _FCSN  =1'b1;
      assign  _MODE  =spatz_req.op_cfg.dimc.flags[1:0];
      assign  _FA    ='x;
      assign  _FD    ='x;
      assign  _ADDIN =operand1[23:0];
      assign  _D     =256'b0;
      assign  _RA    ={spatz_req.op_cfg.dimc.k_row, spatz_req.op_cfg.dimc.sec};
      assign  _WA    =7'bxx;
      assign  _RCSN  =1'b0;
      assign  _RCSN0 =1'b0;
      assign  _RCSN1 =1'b0;
      assign  _RCSN2 =1'b0;
      assign  _RCSN3 =1'b0;
      assign  _WCSN  =1'b1;
      assign  _WEN   =1'b1;
    end: gen_dimc_DSS
  end:DIMC_DECODE

  // DIMC instance
  DIMC_18_fixed #(
    .SECTION_WIDTH(SECTION_WIDTH)
  )i_dimc (
    .RCK(clk_i),                                                    // Main clock
    .RESETn(rst_ni),                                                // Active-low reset
    .READYN(dimc_ready),                                            // Active-low ready (output valid)
    .COMPE(_COMPE),                                                 // Operation mode (1=compute, 0=memory)
    .FCSN(_FCSN),                                                   // Feature buffer chip select (active-low)
    .MODE(_MODE),                                                   // Bit resolution (0=1b, 1=2b, 2=4b) spatz_req.mode we can aslo use it
    .FA(_FA),                                                       // Feature buffer address we use 
    .FD(_FD),                                                       // Feature buffer datas
    .ADDIN(_ADDIN),                                                 // Bias/partial sum input
    .SOUT(dimc_result_4bit[0]),                                     // Sum output (LSB of result)
    .RES_OUT(dimc_result_4bit[3:1]),                                // Result output (MSBs of 4-bit result)
    .PSOUT(dimc_psout),                                             // Pre-ReLU output
    .Q(_Q),                                                         // Memory output (unused)
    .D(_D),                                                         // Memory input (unused)
    .RA(_RA),                                                       // Memory address (row address)
    .WA(_WA),                                                       // Write address (when write command have provided)
    .RCSN (_RCSN),                                                  // Read chip select (active-low)
    .RCSN0(_RCSN0),                                                 // Computation control
    .RCSN1(_RCSN1),                                                 // Computation control
    .RCSN2(_RCSN2),                                                 // Computation control
    .RCSN3(_RCSN3),                                                 // Computation control
    .WCK(clk_i),                                                    // Write clock
    .WCSN(_WCSN),                                                   // Write chip select (active-low)
    .WEN(_WEN),                                                     // Write enable (active-low)
    .M(_M),                                                         // Bitwise write mask (unused)
    .MCT(_MCT)                                                        // Masking coding thermometric (unused)
  );

  // ========== DIMC RESULT HANDLING ==========

  // Calculate which 32-bit element to write (0-7 for 256-bit register)
  assign current_element_idx = dimc_element_sel; // Direct from instruction
  assign dimc_in_ready = {N_FU*ELENB{~dimc_ready}};
  assign dimc_result_valid = {N_FU*ELENB{~dimc_ready}};
  assign dimc_32bit_result = {8'b0, dimc_psout}; // Zero-extend to 32-bit
 
 always_comb begin
  dimc_result_wide = '0;
  // Place 32-bit result at element position specified by instruction
  // Each element is 32 bits, so multiply by 32
  dimc_result_wide[current_element_idx * 32 +: 32] = dimc_32bit_result;
 end

 assign dimc_result = dimc_result_wide;
  
  // DIMC busy signal
  assign is_dimc_busy = (state_q == VFU_RunningDIMC) && ~dimc_ready;
 
 //----------  
 // FIFO to track vd and wbe for in-flight DIMC computations
 //-----------
 assign dimc_element_sel = (dimc_fifo_count > 0 && !dimc_ready) ? 
                         dimc_vd_fifo[dimc_fifo_head][7:5] :  // Delayed from FIFO
                         spatz_req.op_cfg.dimc.flags[4:2];    // spatz_req.op_cfg.dimc.flags[4:2]; Extract from immediate
  
 // Override the result_tag assignment to use combinational path
 assign result_tag = (state_q == VFU_RunningDIMC) ? dimc_result_tag_comb : 
                   (state_q == VFU_RunningIPU) ? ipu_result_tag : 
                   fpu_result_tag;

 // Tag is always available from FIFO head
 assign dimc_result_tag_comb = (dimc_fifo_count > 0) ? 
                             dimc_tag_fifo[dimc_fifo_head] : input_tag;

 always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    // Initialize
    dimc_result_tag <= '0;
    for (int i = 0; i < 4; i++) begin
      dimc_vd_fifo[i] <= '0;
      dimc_tag_fifo[i] <= '0;
    end
    dimc_fifo_head <= '0;
    dimc_fifo_tail <= '0;
    dimc_fifo_count <= '0;
  end else begin
    // ===== FIFO WRITE =====
    // When DSS/DPS computation starts
    if (compute_pulse && state_q == VFU_RunningDIMC && 
        spatz_req.op_cfg.dimc.cmd inside {DIMC_CMD_DSS, DIMC_CMD_DPS} &&
        dimc_fifo_count < 4) begin
      
      // Push to FIFO
      dimc_vd_fifo[dimc_fifo_tail] <= {spatz_req.op_cfg.dimc.flags[4:2], spatz_req.vd};
      //                               element_sel[2:0]                 vd[4:0]  spatz_req.vd;
      dimc_tag_fifo[dimc_fifo_tail] <= input_tag;
      dimc_fifo_tail <= dimc_fifo_tail + 1;
      dimc_fifo_count <= dimc_fifo_count + 1;
      
      $display("[DIMC FIFO] Time %t: PUSH: vd_reg=%0d (tail=%0d, count=%0d)", 
                $time, spatz_req.vd, dimc_fifo_tail, dimc_fifo_count + 1);
    end
    
    // ===== POP WHEN RESULT ARRIVES =====
    // When DIMC result is ready
    if (!dimc_ready && dimc_fifo_count > 0) begin

      // Extract vd and element_sel before popping updated
      automatic logic [4:0] current_vd = dimc_vd_fifo[dimc_fifo_head][4:0];
      automatic logic [2:0] current_element_sel = dimc_vd_fifo[dimc_fifo_head][7:5];
      
      // Update vd address for tag
      dimc_tag_fifo[dimc_fifo_head].vd_addr <= 
        current_vd << $clog2(NrWordsPerVector);

      // Also update the current element selector for the write
      // This gets used by the element selection logic
      //delayed_element_sel <= current_element_sel;
      // Pop from FIFO

      dimc_fifo_head <= dimc_fifo_head + 1;
      dimc_fifo_count <= dimc_fifo_count - 1;
      
      $display("[DIMC FIFO] Time %t: POP: vd_reg=%0d (result ready)",
               $time, dimc_vd_fifo[dimc_fifo_head]);
    end
    
    // ===== UPDATE REGISTERED TAG =====
    // Keep registered version in sync
    dimc_result_tag <= dimc_result_tag_comb;
    
    // ===== RESET FOR LD_F/LD_K =====
    if (state_q == VFU_RunningDIMC && 
        spatz_req.op_cfg.dimc.cmd inside {DIMC_CMD_LD_F, DIMC_CMD_LD_K}) begin
      // Clear FIFO
      dimc_fifo_head <= '0;
      dimc_fifo_tail <= '0;
      dimc_fifo_count <= '0;
    end
  end
 end
 // DEBUG: Track DIMC ready signal and actual writes
 always @(posedge clk_i) begin
  static logic dimc_ready_last = 1'b1;

  // Track dimc_ready changes
  if (dimc_ready != dimc_ready_last) begin
    $display("[DIMC READY] Time %0t: %0b -> %0b", $time, dimc_ready_last, dimc_ready);
    dimc_ready_last <= dimc_ready;
  end
 end

  // DIMC outputs
  assign dimc_psout_o   = dimc_psout;
  assign dimc_sout_o    = dimc_result_4bit[0];
  assign dimc_res_out_o = dimc_result_4bit[3:1];
  //assign vrf_wdata_o    = _Q;

endmodule : spatz_vfu