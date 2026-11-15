# Host port and loader

Draft 0.1 of 2026-11-14, not frozen. Executable form: `spec/model.ml` (`host_cycle`, `reg_peek`,
`reg_write`, `prog_write`); examples in `spec/test/test_host.ml`. Read `machine.md` first.

## 1. Pins and sampling

SPI target, mode 0, most significant bit first. `ui[0]` SCK, `ui[1]` MOSI, `ui[2]` CS_N, `uo[0]` MISO.
The pin assignment is provisional until the floorplan.

There is no second clock domain. SCK, MOSI and CS_N are the synchronised pins P16, P17, P18 of the
machine model; the port acts on edges of the synchronised SCK:

- rising edge with CS_N low: MOSI of the same cycle is shifted in;
- falling edge with CS_N low: MISO takes the next output bit (the pad changes in the next cycle);
- CS_N high: the transaction ends, MISO is 0.

On the model, which has no pad delay, transfers are correct down to an SCK period of 4 clock cycles and
wrong at 2. Until pad timing is known the rule for the host is a period of at least 10 clock cycles
(4.8 MHz at 48 MHz), an estimate.

## 2. Transactions

One transaction is one CS_N low phase: a command byte, an address, then data words.

| command | meaning | after the command byte |
|---|---|---|
| 0x10 | read register, same address for every word | address (8), then 16-bit words out |
| 0x11 | read registers, address increments | as 0x10 |
| 0x20 | write register, same address | address (8), then 16-bit words in |
| 0x21 | write registers, address increments | as 0x20 |
| 0x30 | read program memory | address (16), one unused byte, then 32-bit words out |
| 0x40 | write program memory | address (16), then 32-bit words in |
| 0x50 | read data memory | address (16), one unused byte, then 16-bit words out |
| 0x60 | write data memory | address (16), then 16-bit words in |

Any other command byte sets host status bit 0 and the rest of the transaction is ignored. Memory
addresses increment per word; only the low 9 (program) or 10 (data) bits are used.

- A register write takes effect in the cycle in which the last bit of its word is shifted in. A register
  read takes its value in the cycle in which the last bit before the word is shifted in; a read with a
  side effect (the mailbox) takes effect only when the last bit of that word has been clocked.
- Memory accesses are carried out in the system slot of the round (`machine.md`, section 2), at most 4
  cycles after the word is complete or the address is known, or one round later for each data-memory
  slot the line unit takes. Reads are fetched one word ahead.
- The data memory is not gated: the host can read and write any word at any time, including words inside
  a running thread's data window. That is the intended way to pass bulk data.

## 3. Loader and load gate

A thread can only be started on a program window that holds a completed, checked load.

1. With the thread stopped, set its window (`PBASE`, `PSIZE`).
2. Write 3 (load begin) to its `CTRL` register. Refused if the thread runs, the size is 0 or the window
   would pass the end of the memory.
3. Write the program words to the window in ascending order, starting at its first word.
4. Write the digest to `LOADEND`. If exactly `PSIZE` words were written and the digest the chip computed
   equals the value written, the window is **loaded**; otherwise host status bit 1 is set.
5. Write 1 (start) to `CTRL`. Refused unless the window is loaded, the thread is stopped, no commit of it
   is pending and its data window lies inside the memory.

The digest is CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF) over the 32-bit words in
address order, bit 31 first. It detects transfer errors; it is not a security measure.

A program-memory write

- inside the window of a running or waiting thread is refused: nothing is written;
- inside a window that is being loaded must be the next word in sequence, else it is refused;
- inside any other window is carried out, and that window is no longer loaded;
- outside every window is carried out.

Changing `PBASE` or `PSIZE` makes the window not loaded. Refusals set host status bit 2.

Consequences: a running thread's window cannot change; a thread that runs was started on a window whose
contents had the reported digest; one thread can be reloaded while the others run.

Start sets `pc` to the entry point, clears the staged set, EV, LATE and the slack minimum, and leaves the
registers, t and p as they are. Stop (write 2 to `CTRL`) makes the thread idle and puts its pins into the
safe pattern through a pending commit, exactly as a fault does.

## 4. Registers

16-bit registers, 8-bit addresses. R read, W write, W1C write 1 to clear. Addresses not listed read 0 and
ignore writes.

| address | name | access | content |
|---|---|---|---|
| 0x00 | ID | R | 0x8401 |
| 0x01 | INFO | R | [3:0] rule slots, [7:4] mailbox depth, [11:8] threads |
| 0x02 | NOW_LO | R | `now[15:0]`; reading it latches `now[31:16]` |
| 0x03 | NOW_HI | R | the latched high half |
| 0x04 | HSTAT | R, W1C | 0 unknown command, 1 load error, 2 refused, 3 mailbox to thread was full, 4 mailbox from thread was empty |
| 0x08, 0x09 | PAD_VALUE, PAD_DIR | R | the pad registers |
| 0x0A, 0x0B | PINS_LO, PINS_HI | R | the 24 pins as a thread reads them |
| 0x10..0x13 | OWNER0..3 | R/W | owner of pin 4k+j in bits [4j+2:4j]: 0..2 thread, other values none. P8 is fixed |
| 0x14 | OD | R/W | open-drain mode of P0..P7 |
| 0x15, 0x16 | SAFE_VAL, SAFE_DIR | R/W | the safe pattern |
| 0x18, 0x19 | FILT0, FILT1 | R/W | filter length, 2 bits per pin, of P0..P7 and P16..P23 |
| 0x20..0x22 | FAIL_INFO, FAIL_LO, FAIL_HI | R | [15] valid, [14] maximum, [13] a blame came first, [3:0] rule; cycle |
| 0x24..0x26 | BLAME_INFO, BLAME_LO, BLAME_HI | R | as FAIL, without bit 13 |
| 0x27 | VERDICT_CLEAR | W | bit 0: clear both records |
| 0x30..0x36 | trace | | see `trace.md` |

Thread T at 0x40 + 16 T:

| offset | name | access | content |
|---|---|---|---|
| 0 | CTRL | W | 1 start, 2 stop, 3 load begin |
| 1 | STATE | R | [2:0] 0 idle, 1 running, 2 waiting for an event, 3 halted, 4 fault; [7:4] fault (1 ILLEGAL, 2 PCBOUND, 3 DBOUND, 4 PINOWN, 5 LATE, 6 IOPERM, 7 TRAP, 8 RULE); [15:8] trap code or rule |
| 2 | ENTRY | R/W | entry point used by start |
| 3, 4 | PBASE, PSIZE | R/W | program window |
| 5, 6 | DBASE, DSIZE | R/W | data window |
| 7 | POLICY | R/W | bit 0: strict late policy |
| 8 | MBOX_IN | W | append a word to the mailbox to the thread |
| 9 | MBOX_OUT | R | first word of the mailbox from the thread; removed when the word has been read completely |
| 10 | MBOX_STAT | R | bit 0: mailbox to the thread not full; bit 1: mailbox from the thread not empty |
| 11 | SLACK | R | slack minimum |
| 12 | DIGEST | R | digest of the last completed load |
| 13 | LOADEND | W | expected digest |
| 14 | FLAGS | R | 0 loaded, 1 loading, 2 LATE, 3 EV |
| 15 | PC | R | program counter |

ENTRY, PBASE, PSIZE, DBASE and DSIZE can be written only while the thread is stopped.

Rule k at 0x80 + 16 k: offsets 0 to 5 are the six words of the rule table entry (`rules.md`, section 2),
R/W; writing word 5 also resets the rule's state, flags and observations. Offset 6 flags, 7 observed
minimum, 8 observed maximum, 9 current length, all R. Load a rule by writing word 5 with enable 0, then
words 0 to 4, then word 5.

Line unit at 0xC0 + j: register j of `line.md`, section 3, including the owner register (j = 22).

## 5. State

SPI side about 130 bits (two 32-bit shift registers, a 32-bit read-ahead word, address, command, bit
counter). Loader 54 bits per thread (flags, word count, running digest, digest, entry point). Host status
and the `now` latch 21 bits. About 313 bits, plus the mailboxes counted with the threads.

## 6. Tests

| test | shows |
|---|---|
| a session over SPI | identification, pin owner, window, load with digest, program read-back, start, mailbox both ways, data memory, `now` |
| load gate | every refusal of section 3, the wrong digest, the wrong order, stop |
| SCK period on the model | correct at 10, 8, 6 and 4 cycles, wrong at 2 |
| loading over SPI and loading directly are the same | identical waveform of the UART program |

## 7. Open points

1. SCK limit with real pad delays.
2. (closed) The data memory's system slot goes to the line unit, then the host, then the trace. The
   SCK rule of section 2 was measured without line unit traffic; a host data-memory access that loses
   a slot is one round late.
3. Whether the digest should also cover the pin configuration and the rule table.
