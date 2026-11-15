"""Small SCOMP assembler + instruction simulator with a TimeKeeper model.
Checks SCASM-style syntax limits (LOADI/ADDI 11-bit signed, SHIFT -15..15)."""
import re

OPS = {'LOAD', 'STORE', 'ADD', 'SUB', 'JUMP', 'JNEG', 'JPOS', 'JZERO', 'JNZ', 'AND', 'OR', 'XOR',
       'SHIFT', 'ADDI', 'LOADI', 'CALL', 'RETURN', 'IN', 'OUT', 'NOP'}


def num(tok, syms):
    t = tok.strip()
    neg = t.startswith('-')
    if neg: t = t[1:]
    if t.upper().startswith('&H'): v = int(t[2:], 16)
    elif t.upper().startswith('&B'): v = int(t[2:], 2)
    elif t.isdigit(): v = int(t)
    else: v = syms[t]
    return -v if neg else v


def assemble(path):
    lines = []
    for raw in open(path):
        line = raw.split(';')[0].strip()
        if not line: continue
        label = None
        m = re.match(r'^(\w+):\s*(.*)$', line)
        if m: label, line = m.group(1), m.group(2).strip()
        parts = line.split(None, 1)
        lines.append((label, parts[0].upper() if parts else None, parts[1].strip() if len(parts) > 1 else None))
    syms, pc = {}, 0
    for label, op, arg in lines:                       # pass 1
        if op == 'EQU': syms[label] = arg; continue
        if op == 'ORG': pc = int(arg); continue
        if label: syms[label] = pc
        if op: pc += 1
    for k, v in list(syms.items()):                    # resolve EQUs
        if isinstance(v, str): syms[k] = num(v, syms)
    mem, prog, pc = {}, {}, 0
    for label, op, arg in lines:                       # pass 2
        if op in ('EQU', None): continue
        if op == 'ORG': pc = int(arg); continue
        if op == 'DW': mem[pc] = num(arg, syms) & 0xFFFF
        else:
            assert op in OPS, op
            val = num(arg, syms) if arg else 0
            if op in ('LOADI', 'ADDI'): assert -1024 <= val <= 1023, (op, val)
            elif op == 'SHIFT': assert -15 <= val <= 15
            elif op not in ('RETURN', 'NOP'): assert 0 <= val < 2048, (op, arg)
            prog[pc] = (op, val)
        pc += 1
    assert pc <= 2048
    return prog, mem, syms, pc


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


class TimeKeeperModel:
    """Same behaviour as TimeKeeper.vhd, in microseconds."""
    UNIT_MS = [1, 10, 100, 1000]

    def __init__(self, base):
        self.base = base
        self.ch = [dict(count=0, reload=0, mode=0, unit=0, pause=0, bcd=0, run=0, done=0, acc=0) for _ in range(4)]

    def owns(self, a): return self.base <= a <= self.base + 8

    @staticmethod
    def bcd(v):
        if v > 9999: return 0x9999
        return int(str(v), 16)

    def read(self, a):
        off = a - self.base
        if off == 8:
            v = 0
            for i, c in enumerate(self.ch):
                v |= c['done'] << i
                v |= (c['run'] & (1 - c['pause'])) << (4 + i)
                c['done'] = 0
            return v
        c = self.ch[off >> 1]
        if off & 1:
            d = c['done']; c['done'] = 0
            return d
        return self.bcd(c['count']) if c['bcd'] else c['count']

    def write(self, a, v):
        off = a - self.base
        if off == 8: return
        c = self.ch[off >> 1]
        if off & 1:
            if ((v >> 2) & 3) != c['unit']: c['acc'] = 0
            c.update(mode=v & 3, unit=(v >> 2) & 3, pause=(v >> 4) & 1, bcd=(v >> 5) & 1)
        else:
            c.update(count=v, reload=v, acc=0, done=0, run=1 if (c['mode'] & 2 or v) else 0)

    def advance(self, us):
        for c in self.ch:
            if not c['run'] or c['pause']: continue
            c['acc'] += us
            unit = self.UNIT_MS[c['unit']] * 1000
            while c['acc'] >= unit and c['run']:
                c['acc'] -= unit
                if c['mode'] & 2:
                    c['count'] = min(c['count'] + 1, 0xFFFF)
                elif c['count'] < 2:
                    c['done'] = 1
                    if c['mode'] & 1: c['count'] = c['reload']
                    else: c['count'] = 0; c['run'] = 0
                else:
                    c['count'] -= 1


class Board:
    def __init__(self, tk_base=0x0F0):
        self.sw = 0; self.leds = 0; self.hex0 = 0; self.hex1 = 0
        self.tk = TimeKeeperModel(tk_base)

    def read(self, a):
        if a == 0x000: return self.sw
        if self.tk.owns(a): return self.tk.read(a)
        return 0

    def write(self, a, v):
        if a == 0x001: self.leds = v & 0x3FF
        elif a == 0x004: self.hex0 = v
        elif a == 0x005: self.hex1 = v & 0xFF
        elif self.tk.owns(a): self.tk.write(a, v)


class SCOMP:
    US_PER_INSTR = 0.5          # ~6 clocks per instruction at 12 MHz

    def __init__(self, path, board):
        self.prog, mem, self.syms, _ = assemble(path)
        self.mem = dict(mem)
        self.b = board
        self.pc = 0; self.ac = 0; self.stack = []; self.t_us = 0.0; self._frac = 0.0

    def step(self):
        op, val = self.prog[self.pc]
        self.pc += 1
        ac = self.ac
        m = lambda: self.mem.get(val, 0)
        if op == 'LOAD': self.ac = m()
        elif op == 'STORE': self.mem[val] = ac
        elif op == 'ADD': self.ac = (ac + m()) & 0xFFFF
        elif op == 'SUB': self.ac = (ac - m()) & 0xFFFF
        elif op == 'ADDI': self.ac = (ac + val) & 0xFFFF
        elif op == 'LOADI': self.ac = val & 0xFFFF
        elif op == 'AND': self.ac = ac & m()
        elif op == 'OR': self.ac = ac | m()
        elif op == 'XOR': self.ac = ac ^ m()
        elif op == 'SHIFT': self.ac = ((ac << val) if val >= 0 else (s16(ac) >> -val)) & 0xFFFF
        elif op == 'JUMP': self.pc = val
        elif op == 'JNEG': self.pc = val if s16(ac) < 0 else self.pc
        elif op == 'JPOS': self.pc = val if s16(ac) > 0 else self.pc
        elif op == 'JZERO': self.pc = val if ac == 0 else self.pc
        elif op == 'JNZ': self.pc = val if ac != 0 else self.pc
        elif op == 'CALL': self.stack.append(self.pc); self.pc = val
        elif op == 'RETURN': self.pc = self.stack.pop()
        elif op == 'IN': self.ac = self.b.read(val) & 0xFFFF
        elif op == 'OUT': self.b.write(val, ac)
        self.t_us += self.US_PER_INSTR
        self._frac += self.US_PER_INSTR
        if self._frac >= 1:
            whole = int(self._frac); self._frac -= whole
            self.b.tk.advance(whole)

    def run_ms(self, ms):
        end = self.t_us + ms * 1000
        while self.t_us < end: self.step()

    def var(self, name): return self.mem.get(self.syms[name], 0)
