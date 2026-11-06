//==- RISCVSchedVeeREH1.td - VeeR EH1 Scheduling Definitions -*- tablegen -*-=//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

// VeeR EH1 (formerly Western Digital SweRV EH1):
// https://github.com/chipsalliance/Cores-VeeR-EH1
//
// VeeR EH1 is a 9-stage (F1, F2, Align, Decode, EX1-EX4, WB), 2-wide in-order
// RV32IMC core. The two issue slots (i0, i1) each have a primary ALU in EX1
// and a secondary ALU in EX4. Loads, stores and multiplies are shared between
// both slots, so only one LSU op and one multiply can issue per cycle.
//
// An ALU op whose source is produced by a load or a multiply that is still in
// EX1/EX2 does not stall at decode. It executes in the EX4 secondary ALU, and
// its result is not available to non-ALU consumers (load/store address,
// multiply) until it reaches EX4. The model gives load and multiply results
// their full latency for ALU consumers, which matches the measured cost of
// load -> ALU -> address and multiply -> ALU -> address chains.
//
// Branches read their operands late, so load and multiply results feed them
// without a stall. A branch that executes in the secondary ALU resolves in
// EX4, which raises its mispredict penalty from about 5 to about 8 cycles.
// Store data is read late too, but only load results are forwarded to it,
// a store of a multiply result waits for the full multiply latency.
//
// Divide and remainder use a radix-2 iterative divider with early outs for
// small quotients. They stall decode until they finish, so nothing overlaps
// with them.
//
// Results are committed in order at a fixed stage, so a short-latency
// instruction never waits for an older long-latency one to write back.

def VeeREH1Model : SchedMachineModel {
  let MicroOpBufferSize = 0;
  let IssueWidth = 2;
  let LoadLatency = 3;
  let MispredictPenalty = 5;
  let CompleteModel = 0;
  let UnsupportedFeatures = [HasStdExtZbkb, HasStdExtZbkc, HasStdExtZbkx,
                             HasStdExtZknd, HasStdExtZkne, HasStdExtZknh,
                             HasStdExtZksed, HasStdExtZksh, HasStdExtZkr,
                             HasVInstructions];
}

let SchedModel = VeeREH1Model in {

let BufferSize = 0 in {
// One ALU per issue slot.
def VeeREH1ALU0 : ProcResource<1>;
def VeeREH1ALU1 : ProcResource<1>;
def VeeREH1ALU : ProcResGroup<[VeeREH1ALU0, VeeREH1ALU1]>;
def VeeREH1LSU : ProcResource<1>;
def VeeREH1MUL : ProcResource<1>;
def VeeREH1DIV : ProcResource<1>;
}

// Results are written back at a fixed stage, so a short-latency instruction
// never waits behind an older long-latency one. Without RetireOOO, llvm-mca's
// in-order model would stall every ALU op issued after a load or multiply
// until that result is written back.
let RetireOOO = true in {

// Branching. Branches execute in either ALU. No instruction can issue in i1
// after a JAL or JALR in i0.
def : WriteRes<WriteJmp, [VeeREH1ALU]>;
let EndGroup = true in {
def : WriteRes<WriteJal, [VeeREH1ALU]>;
def : WriteRes<WriteJalr, [VeeREH1ALU]>;
}
// Short forward branch: the branch and the ALU op it skips, one per ALU.
let NumMicroOps = 2 in
def : WriteRes<WriteSFB, [VeeREH1ALU0, VeeREH1ALU1]>;

// Integer arithmetic and logic.
def : WriteRes<WriteIALU32, [VeeREH1ALU]>;
def : WriteRes<WriteIALU, [VeeREH1ALU]>;
def : WriteRes<WriteShiftImm32, [VeeREH1ALU]>;
def : WriteRes<WriteShiftImm, [VeeREH1ALU]>;
def : WriteRes<WriteShiftReg32, [VeeREH1ALU]>;
def : WriteRes<WriteShiftReg, [VeeREH1ALU]>;

// Integer multiplication: 3-stage pipelined multiplier, one per cycle.
let Latency = 3 in {
def : WriteRes<WriteIMul, [VeeREH1MUL]>;
def : WriteRes<WriteIMul32, [VeeREH1MUL]>;
}

// Integer division/remainder. Latency is for a full 32-bit quotient, small
// quotients finish early. Decode stalls until the divider finishes, so no
// other instruction overlaps with it. Measured on the RTL: after a worst-case
// divide the next instruction issues 38 cycles later (39 after a remainder).
// A second divide can issue a little earlier, after 35 (36), but the model
// cannot express that without releasing the other units early too, so every
// unit is held for the full latency.
defvar VeeREH1DivResources = [VeeREH1DIV, VeeREH1ALU0, VeeREH1ALU1,
                              VeeREH1LSU, VeeREH1MUL];
let BeginGroup = true, EndGroup = true in {
let Latency = 38, ReleaseAtCycles = [38, 38, 38, 38, 38] in {
def : WriteRes<WriteIDiv32, VeeREH1DivResources>;
def : WriteRes<WriteIDiv, VeeREH1DivResources>;
}
let Latency = 39, ReleaseAtCycles = [39, 39, 39, 39, 39] in {
def : WriteRes<WriteIRem32, VeeREH1DivResources>;
def : WriteRes<WriteIRem, VeeREH1DivResources>;
}
}

// Memory. DCCM load data returns in EX3.
def : WriteRes<WriteSTB, [VeeREH1LSU]>;
def : WriteRes<WriteSTH, [VeeREH1LSU]>;
def : WriteRes<WriteSTW, [VeeREH1LSU]>;
def : WriteRes<WriteSTD, [VeeREH1LSU]>;
let Latency = 3 in {
def : WriteRes<WriteLDB, [VeeREH1LSU]>;
def : WriteRes<WriteLDH, [VeeREH1LSU]>;
def : WriteRes<WriteLDW, [VeeREH1LSU]>;
def : WriteRes<WriteLDD, [VeeREH1LSU]>;
}

// CSR accesses issue alone in i0.
let BeginGroup = true, EndGroup = true in
def : WriteRes<WriteCSR, [VeeREH1ALU]>;
def : WriteRes<WriteNop, []>;

} // RetireOOO = true

def : InstRW<[WriteIALU], (instrs COPY)>;

//===----------------------------------------------------------------------===//
// Bypasses

defvar VeeREH1LoadWrites = [WriteLDB, WriteLDH, WriteLDW, WriteLDD];
defvar VeeREH1LateWrites = !listconcat(VeeREH1LoadWrites,
                                       [WriteIMul, WriteIMul32]);
defvar VeeREH1ALUWrites = [WriteIALU, WriteIALU32, WriteShiftImm,
                           WriteShiftImm32, WriteShiftReg, WriteShiftReg32];

// Branches read their operands late.
def : ReadAdvance<ReadJmp, 3, VeeREH1LateWrites>;
// The short forward branch pseudo reads its operands at full latency: giving
// its branch the late read costs aha-mont64 3% and depthconv 4% on the RTL.
def : ReadAdvance<ReadSFBJmp, 0>;
def : ReadAdvance<ReadSFBALU, 0>;
def : ReadAdvance<ReadJalr, 0>;
def : ReadAdvance<ReadCSR, 0>;
// Store data is read late. An i0 ALU op can also feed the store data of an i1
// store in the same cycle, and a load result is forwarded to store data two
// cycles early. A multiply result is not forwarded, so a store of it waits
// for the full multiply latency (measured: 2 stall cycles).
def : ReadAdvance<ReadStoreData, 1,
                  !listconcat(VeeREH1ALUWrites, VeeREH1LoadWrites),
                  !listconcat(!listsplat(0, !size(VeeREH1ALUWrites)),
                              !listsplat(2, !size(VeeREH1LoadWrites)))>;
// Load results are bypassed from EX2 to the address generator and multiplier.
def : ReadAdvance<ReadMemBase, 1, VeeREH1LoadWrites>;
def : ReadAdvance<ReadIMul, 1, VeeREH1LoadWrites>;
def : ReadAdvance<ReadIMul32, 1, VeeREH1LoadWrites>;
def : ReadAdvance<ReadIALU, 0>;
def : ReadAdvance<ReadIALU32, 0>;
def : ReadAdvance<ReadShiftImm, 0>;
def : ReadAdvance<ReadShiftImm32, 0>;
def : ReadAdvance<ReadShiftReg, 0>;
def : ReadAdvance<ReadShiftReg32, 0>;
def : ReadAdvance<ReadIDiv, 0>;
def : ReadAdvance<ReadIDiv32, 0>;
def : ReadAdvance<ReadIRem, 0>;
def : ReadAdvance<ReadIRem32, 0>;

//===----------------------------------------------------------------------===//
// Unsupported extensions
defm : UnsupportedSchedA;
defm : UnsupportedSchedF;
defm : UnsupportedSchedV;
defm : UnsupportedSchedZabha;
defm : UnsupportedSchedZba;
defm : UnsupportedSchedZbb;
defm : UnsupportedSchedZbc;
defm : UnsupportedSchedZbs;
defm : UnsupportedSchedZbkb;
defm : UnsupportedSchedZbkx;
defm : UnsupportedSchedZfa;
defm : UnsupportedSchedZvk;
defm : UnsupportedSchedXsf;
}
