# SPDX-License-Identifier: Apache-2.0
#
# Physical skeleton (branch probe-skeleton): smoke test only. The skeleton is a test load whose
# function is not the specification; the test checks that after reset no pin is driven and every
# output is defined.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    cocotb.start_soon(Clock(dut.clk, 20830, unit="ps").start())
    dut.ena.value = 1
    dut.ui_in.value = 0b100  # host select high (idle)
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 200)
    assert dut.uio_oe.value.is_resolvable and int(dut.uio_oe.value) == 0, dut.uio_oe.value
    assert dut.uo_out.value.is_resolvable, dut.uo_out.value
    assert dut.uio_out.value.is_resolvable, dut.uio_out.value
    dut._log.info("uo_out %s uio_out %s uio_oe %s", dut.uo_out.value, dut.uio_out.value, dut.uio_oe.value)
