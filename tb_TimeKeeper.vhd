-- tb_TimeKeeper.vhd : self-checking testbench for TimeKeeper
-- Emulates SCOMP IN/OUT cycles (CS high for one clock). CLK_FREQ = 10 kHz so
-- 1 ms = 10 clocks and the whole test runs quickly.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY tb_TimeKeeper IS
END tb_TimeKeeper;

ARCHITECTURE sim OF tb_TimeKeeper IS
	CONSTANT FCLK : INTEGER := 10000;
	CONSTANT TCLK : TIME := 100 us;

	SIGNAL clk, resetn, cs, iow : STD_LOGIC := '0';
	SIGNAL addr : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
	SIGNAL data : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => 'Z');
	SIGNAL fails : INTEGER := 0;
	SIGNAL stop  : BOOLEAN := FALSE;
BEGIN
	clk <= NOT clk AFTER TCLK/2 WHEN NOT stop;

	dut : ENTITY work.TimeKeeper
		GENERIC MAP (CLK_FREQ => FCLK)
		PORT MAP (CLOCK => clk, RESETN => resetn, CS => cs, IO_WRITE => iow,
		          IO_ADDR => addr, IO_DATA => data);

	PROCESS
		VARIABLE v : STD_LOGIC_VECTOR(15 DOWNTO 0);
		VARIABLE t0 : TIME;
		VARIABLE k : INTEGER;

		PROCEDURE io_out(a : INTEGER; d : INTEGER) IS
		BEGIN
			WAIT UNTIL FALLING_EDGE(clk);
			addr <= STD_LOGIC_VECTOR(to_unsigned(a, 4));
			data <= STD_LOGIC_VECTOR(to_unsigned(d, 16));
			iow <= '1'; cs <= '1';
			WAIT UNTIL FALLING_EDGE(clk);
			cs <= '0'; iow <= '0'; data <= (OTHERS => 'Z');
		END PROCEDURE;

		PROCEDURE io_in(a : INTEGER; r : OUT STD_LOGIC_VECTOR(15 DOWNTO 0)) IS
		BEGIN
			WAIT UNTIL FALLING_EDGE(clk);
			addr <= STD_LOGIC_VECTOR(to_unsigned(a, 4));
			iow <= '0'; cs <= '1';
			WAIT UNTIL RISING_EDGE(clk);      -- SCOMP latches AC here
			r := data;
			WAIT UNTIL FALLING_EDGE(clk);
			cs <= '0';
		END PROCEDURE;

		PROCEDURE check(name : STRING; got : STD_LOGIC_VECTOR(15 DOWNTO 0); exp : INTEGER) IS
		BEGIN
			IF to_integer(UNSIGNED(got)) /= exp THEN
				REPORT "FAIL " & name & ": got " & INTEGER'IMAGE(to_integer(UNSIGNED(got)))
				     & " expected " & INTEGER'IMAGE(exp) SEVERITY ERROR;
				fails <= fails + 1;
			ELSE
				REPORT "ok   " & name & " = " & INTEGER'IMAGE(exp);
			END IF;
		END PROCEDURE;

		PROCEDURE check_range(name : STRING; got, lo, hi : INTEGER) IS
		BEGIN
			IF got < lo OR got > hi THEN
				REPORT "FAIL " & name & ": got " & INTEGER'IMAGE(got) & " expected "
				     & INTEGER'IMAGE(lo) & ".." & INTEGER'IMAGE(hi) SEVERITY ERROR;
				fails <= fails + 1;
			ELSE
				REPORT "ok   " & name & " = " & INTEGER'IMAGE(got);
			END IF;
		END PROCEDURE;
	BEGIN
		resetn <= '0';
		WAIT FOR 5 * TCLK;
		resetn <= '1';
		WAIT FOR 5 * TCLK;

		-- 0. tri-state: bus released when not selected
		WAIT UNTIL FALLING_EDGE(clk);
		IF data /= "ZZZZZZZZZZZZZZZZ" THEN
			REPORT "FAIL bus not released" SEVERITY ERROR; fails <= fails + 1;
		ELSE
			REPORT "ok   IO_DATA is Z when CS = 0";
		END IF;

		-- 1. reset state
		io_in(0, v);  check("reset CH0_COUNT", v, 0);
		io_in(1, v);  check("reset CH0_CTRL (done)", v, 0);
		io_in(8, v);  check("reset STATUS", v, 0);

		-- 2. one-shot 5 ms on CH0 with default config (no CTRL write)
		io_out(0, 5);
		t0 := NOW;
		io_in(8, v);  check("CH0 running bit", v, 16#10#);
		LOOP
			io_in(1, v);
			EXIT WHEN v(0) = '1';
		END LOOP;
		check_range("one-shot 5 ms elapsed (us)", (NOW - t0) / 1 us, 5000, 5200);
		io_in(1, v);  check("CH0 done cleared by read", v, 0);
		io_in(0, v);  check("CH0 count after one-shot", v, 0);
		io_in(8, v);  check("CH0 stopped", v, 0);

		-- 3. periodic 3 ms on CH1: 10 periods in ~30 ms
		io_out(3, 1);             -- periodic, 1 ms
		io_out(2, 3);
		t0 := NOW; k := 0;
		WHILE NOW - t0 < 30.5 ms LOOP
			io_in(3, v);
			IF v(0) = '1' THEN k := k + 1; END IF;
		END LOOP;
		check_range("periodic 3 ms flags in 30 ms", k, 10, 10);
		io_in(8, v);  check("CH1 still running", v, 16#20#);
		io_out(2, 0);             -- stop
		io_in(8, v);  check("CH1 stopped by writing 0", v, 0);

		-- 4. stopwatch on CH2, 10 ms unit
		io_out(5, 2#0110#);       -- stopwatch, 10 ms
		io_out(4, 0);
		WAIT FOR 55 ms;
		io_in(4, v);  check("stopwatch after 55 ms (10 ms units)", v, 5);
		io_out(5, 2#10110#);      -- pause
		WAIT FOR 40 ms;
		io_in(4, v);  check("stopwatch paused", v, 5);
		io_out(5, 2#00110#);      -- resume (partial unit kept)
		WAIT FOR 50 ms;
		io_in(4, v);  check("stopwatch resumed", v, 10);

		-- 5. BCD read
		io_out(5, 2#110110#);     -- pause + BCD
		io_out(4, 1234);
		io_in(4, v);  check("BCD 1234", v, 16#1234#);
		io_out(4, 9999);
		io_in(4, v);  check("BCD 9999", v, 16#9999#);
		io_out(4, 40000);
		io_in(4, v);  check("BCD saturates", v, 16#9999#);
		io_out(4, 7);
		io_in(4, v);  check("BCD 7", v, 16#0007#);

		-- 6. countdown in seconds read as BCD on CH3 (like a game clock)
		io_out(7, 2#101100#);     -- one-shot, 1 s, BCD
		io_out(6, 12);
		io_in(6, v);  check("countdown BCD start", v, 16#12#);
		WAIT FOR 3.5 sec;
		io_in(6, v);  check("countdown BCD after 3.5 s", v, 16#09#);
		WAIT FOR 9 sec;
		io_in(7, v);  check("12 s countdown done", v, 1);

		-- 7. STATUS register clears all reported flags at once
		io_out(1, 0); io_out(3, 0);      -- CH0, CH1 one-shot 1 ms
		io_out(0, 2); io_out(2, 2);
		WAIT FOR 4 ms;
		io_in(8, v);  check("STATUS shows CH0+CH1 done", v, 16#03#);
		io_in(8, v);  check("STATUS cleared", v, 0);

		-- 8. writing COUNT again restarts and clears DONE
		io_out(0, 1);
		WAIT FOR 3 ms;
		io_out(0, 50);
		io_in(1, v);  check("restart clears DONE", v, 0);

		REPORT "TESTS DONE, failures = " & INTEGER'IMAGE(fails);
		stop <= TRUE;
		WAIT;
	END PROCESS;
END sim;
