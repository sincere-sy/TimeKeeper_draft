import sys
from scomp_sim import SCOMP, Board, assemble

ASM = sys.argv[1]
fails = 0
def check(name, ok, info=''):
    global fails
    print(('ok   ' if ok else 'FAIL ') + name + (f'  [{info}]' if info else ''))
    fails += 0 if ok else 1

prog, mem, syms, size = assemble(ASM)
print(f'assembled: {size} words')

def digits(h): return ((h >> 8) & 0xF, (h >> 4) & 0xF, h & 0xF)

# A. idle until SW9, then spin; reels step at their own rates; clock counts down
b = Board(); cpu = SCOMP(ASM, b)
cpu.run_ms(50)
check('waits for SW9 (Hex0 untouched)', b.hex0 == 0)
b.sw = 0x200; cpu.run_ms(5)
check('round starts: Hex1 = 10 (BCD)', b.hex1 == 0x10, f'{b.hex1:02X}')
seen = [set(), set(), set()]; steps = [0, 0, 0]; prev = digits(b.hex0)
for _ in range(1000):                       # 1 s in 1 ms slices
    cpu.run_ms(1)
    d = digits(b.hex0)
    for i in range(3):
        if d[i] != prev[i]: steps[i] += 1
        seen[i].add(d[i])
    prev = d
check('left reel ~12.5 steps/s (80 ms)', 11 <= steps[0] <= 13, steps[0])
check('center reel ~9 steps/s (110 ms)', 8 <= steps[1] <= 10, steps[1])
check('right reel ~7 steps/s (140 ms)', 6 <= steps[2] <= 8, steps[2])
check('reels cover digits 0-9 only', all(s <= set(range(10)) for s in seen))
# direction: center counts down
r1 = cpu.var('Reel1'); cpu.run_ms(111); r1b = cpu.var('Reel1')
check('center reel counts down', r1b == (r1 - 1) % 10, f'{r1}->{r1b}')
cpu.run_ms(2000)
check('clock after ~3 s shows 07', b.hex1 == 0x07, f'{b.hex1:02X}')

# B. stop reels one by one with switches; round ends, clock freezes
b.sw = 0x201; cpu.run_ms(2); d0 = digits(b.hex0)[0]; cpu.run_ms(500)
check('SW0 stops left reel', digits(b.hex0)[0] == d0)
check('other reels keep spinning', cpu.var('Stopped') == 1)
b.sw = 0x203; cpu.run_ms(300)
b.sw = 0x207; cpu.run_ms(5)
score = b.hex1; h = b.hex0
cpu.run_ms(2000)
check('all stopped -> round over, Hex0 frozen', b.hex0 == h)
check('clock frozen as score (stopped at ~3.9 s -> 07)', b.hex1 == score and score == 0x07, f'{score:02X}')
win = len(set(digits(h))) == 1
check('LEDs off (no jackpot)', b.leds == 0 or win)
b.sw = 0; cpu.run_ms(20)
check('back to idle after switches down', cpu.pc in range(syms['WaitDown'], syms['WaitGo'] + 3))

# C. timeout: nobody touches the switches for 10 s
b = Board(); cpu = SCOMP(ASM, b)
cpu.run_ms(5); b.sw = 0x200; cpu.run_ms(9900)
check('9.9 s: still spinning, Hex1 = 01', b.hex1 == 0x01, f'{b.hex1:02X}')
cpu.run_ms(300)
h = b.hex0; cpu.run_ms(1000)
check('10 s timeout ends round', b.hex0 == h and b.hex1 == 0x00, f'{b.hex1:02X}')

# D. jackpot: raise all three switches at a moment when the digits match
b = Board(); cpu = SCOMP(ASM, b)
cpu.run_ms(5); b.sw = 0x200; cpu.run_ms(2)
hit = None
for t in range(9000):
    cpu.run_ms(1)
    d = digits(b.hex0)
    if d[0] == d[1] == d[2]:
        hit = d; b.sw = 0x207; break
check('found a matching moment to stop', hit is not None, hit)
cpu.run_ms(3)
check('stopped on three equal digits', len(set(digits(b.hex0))) == 1, f'{b.hex0:03X}')
toggles = 0; last = b.leds
for _ in range(2000):
    cpu.run_ms(1)
    if b.leds != last: toggles += 1; last = b.leds
check('jackpot: LEDs blink every 250 ms (~8 toggles in 2 s)', 7 <= toggles <= 9, toggles)
b.sw = 0; cpu.run_ms(10)
check('LEDs off after restart', b.leds == 0)

print('failures =', fails)
