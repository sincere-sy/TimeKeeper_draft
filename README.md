# TimeKeeper: a multi-channel timer peripheral for SCOMP

Draft for team discussion (ECE 2031 project, week 1). Sangyun Lee, L06.

TimeKeeper gives SCOMP four independent timers. Each one can count down once, repeat on a fixed period, or work as a stopwatch, and it counts in 1 ms, 10 ms, 100 ms or 1 s units. A program waits for a timer with two instructions (`IN` then `JZERO`) instead of resetting the 10 Hz timer and comparing counts in a loop.

## Register map

The base address is a placeholder (`&H0F0`). It uses 9 addresses, `base+0` to `base+8`.

| Offset | Name | OUT (write) | IN (read) |
|---|---|---|---|
| 0, 2, 4, 6 | `CHn_COUNT` | Load the count and start. In countdown or periodic mode, writing 0 stops the channel. | Current count: time left, or time elapsed for a stopwatch. Read as BCD if bit 5 of CTRL is set. |
| 1, 3, 5, 7 | `CHn_CTRL` | Configuration (bits below) | `1` if the channel finished since the last read, else `0`. The read clears the flag. |
| 8 | `TK_STATUS` | (none) | Bits 3..0 are the DONE flags of channels 3..0; this read clears them. Bits 7..4 are the RUNNING bits. |

`CHn_CTRL` bits:

| Bits | Field | Values |
|---|---|---|
| 1:0 | mode | `00` one-shot countdown, `01` periodic (auto-reload), `1x` stopwatch (counts up, stops at 65535) |
| 3:2 | unit | `00` 1 ms, `01` 10 ms, `10` 100 ms, `11` 1 s |
| 4 | pause | `1` holds the count |
| 5 | BCD | `1` makes `CHn_COUNT` read in BCD (up to 9999), so it shows as decimal on Hex0 and Hex1 |

At reset every channel is stopped, in one-shot mode, with 1 ms units. That means a plain millisecond delay needs no setup.

## Using it from SCOMP

**Wait 500 ms**
```
        LOADI   500
        OUT     T0_COUNT        ; start a 500 ms countdown
Wait:   IN      T0_CTRL         ; 1 when finished
        JZERO   Wait
```

**Do something every 100 ms**
```
        LOADI   &B0001          ; periodic, 1 ms units
        OUT     T1_CTRL
        LOADI   100
        OUT     T1_COUNT
Loop:   IN      T1_CTRL
        JZERO   Other           ; not time yet: do other work
        CALL    Update          ; runs once per period
Other:  ...
        JUMP    Loop
```

**Show a 30-second countdown in decimal**
```
        LOADI   &B101100        ; one-shot, 1 s units, BCD read
        OUT     T2_CTRL
        LOADI   30
        OUT     T2_COUNT
Show:   IN      T2_COUNT        ; 0x30, 0x29, ... already decimal
        OUT     Hex1
        IN      T2_CTRL
        JZERO   Show
```

**Measure how long a switch is held (short press vs. long press)**
```
        LOADI   &B0110          ; stopwatch, 10 ms units
        OUT     T3_CTRL
        LOADI   0
        OUT     T3_COUNT        ; start at 0 when the switch goes up
        ...                     ; wait for the switch to go down
        IN      T3_COUNT        ; held time in 10 ms units
        ADDI    -50             ; less than 0.5 s?
        JNEG    ShortPress
```

## Adding it to SCOMP

1. Add a chip select for the block in `IO_DECODER`. For base `&H0F0`:
   `TK_EN <= '1' WHEN (IO_CYCLE = '1' AND IO_ADDR(10 DOWNTO 4) = "0001111") ELSE '0';`
   Check that the address block does not collide with an existing peripheral.
2. Connect `CLOCK` to SCOMP's clock, `RESETN` to the system reset, `CS` to `TK_EN`, `IO_WRITE`, `IO_ADDR(3 DOWNTO 0)` and `IO_DATA`.
3. Set the generic `CLK_FREQ` to the real frequency of that clock (the default of 12 MHz is a placeholder). All the timing comes from this value.

## Files

| File | What it is |
|---|---|
| `TimeKeeper.vhd` | The peripheral (VHDL-93) |
| `tb_TimeKeeper.vhd` | Self-checking testbench that drives SCOMP-style IN/OUT cycles (25 checks, all pass in GHDL) |
| `SlotMachine.asm` | Demo program: three reels on Hex0, a 10 s round clock on Hex1, a jackpot that blinks the LEDs |
| `sim/` | Python SCOMP assembler and simulator with a TimeKeeper model, plus demo tests (20 checks, all pass) |

## Open questions for the team

- Are four channels the right number? Is a 16-bit count enough (about 65 s at 1 ms, about 18 hours at 1 s)?
- Should a periodic channel count the periods a program missed, instead of only setting a flag?
- Does clear-on-read for DONE feel natural, or would an explicit acknowledge write be clearer?
- Which base address is free in our `IO_DECODER`?
