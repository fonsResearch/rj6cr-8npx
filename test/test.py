# SPDX-License-Identifier: Apache-2.0
#
# Macro probe: write one word to each SRAM, read both back through the byte selector.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge


def word(p_addr, p_din, d_addr, d_din, write):
    wr, rd = (1, 0) if write else (0, 1)
    return (p_addr | (p_din << 9) | (wr << 41) | (rd << 42)
            | (d_addr << 43) | (d_din << 53) | (wr << 69) | (rd << 70))


async def access(dut, value):
    for k in range(71, -1, -1):
        await FallingEdge(dut.clk)
        dut.ui_in.value = ((value >> k) & 1) | 0b10
    await FallingEdge(dut.clk)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)
    dut.ui_in.value = 0b100
    await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk)
    dut.ui_in.value = 0


async def read_bytes(dut):
    out = []
    for sel in range(6):
        await FallingEdge(dut.clk)
        dut.ui_in.value = sel << 3
        await ClockCycles(dut.clk, 6)
        out.append(int(dut.uo_out.value))
    return out


@cocotb.test()
async def test_project(dut):
    cocotb.start_soon(Clock(dut.clk, 20830, unit="ps").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    cases = [(5, 0xDEADBEEF, 9, 0xBEEF), (300, 0x12345678, 1000, 0xA55A)]
    for p_addr, p_din, d_addr, d_din in cases:
        await access(dut, word(p_addr, p_din, d_addr, d_din, write=True))
    for p_addr, p_din, d_addr, d_din in cases:
        await access(dut, word(p_addr, 0, d_addr, 0, write=False))
        got = await read_bytes(dut)
        want = [(p_din >> (8 * k)) & 0xFF for k in range(4)] + [d_din & 0xFF, d_din >> 8]
        dut._log.info("program[%d], data[%d]: read %s", p_addr, d_addr, " ".join("%02X" % b for b in got))
        assert got == want, (got, want)
