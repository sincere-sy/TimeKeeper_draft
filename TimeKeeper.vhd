-- TimeKeeper.vhd
-- Multi-channel timer peripheral for SCOMP (ECE 2031 project)
--
-- Four independent timer channels. Each channel can be a one-shot countdown,
-- a periodic (auto-reload) timer, or a count-up stopwatch, counting in units
-- of 1 ms, 10 ms, 100 ms, or 1 s. A DONE flag is set when a countdown or a
-- period finishes and clears itself when SCOMP reads it, so software can wait
-- with just "IN / JZERO". The count can optionally be read in BCD so it shows
-- as decimal on the hex displays (SCOMP has no divide instruction).
--
-- Register map (offset from the peripheral's base address, n = 0..3):
--   2n   CHn_COUNT  OUT: load count and start (countdown/periodic: 0 = stop)
--                   IN : current count (remaining or elapsed; BCD if enabled)
--   2n+1 CHn_CTRL   OUT: configuration
--                         [1:0] mode  00 one-shot, 01 periodic, 1x stopwatch
--                         [3:2] unit  00 1 ms, 01 10 ms, 10 100 ms, 11 1 s
--                         [4]   pause (1 = hold the count)
--                         [5]   BCD read of CHn_COUNT (saturates at 9999)
--                   IN : 1 if the channel finished since the last read, else 0
--                        (reading clears the flag)
--   8    TK_STATUS  IN : [3:0] DONE flags of channels 3..0 (reading clears
--                        them), [7:4] RUNNING bits of channels 3..0
--                        (running = counting now: started, not finished,
--                        not paused)
--
-- Reset state: every channel stopped, count 0, one-shot, 1 ms, no pause,
-- binary read. So "LOADI 500 / OUT CH0_COUNT" is a 500 ms countdown with no
-- configuration at all.
--
-- Bus timing: CS comes from IO_DECODER (IO_CYCLE and the address block
-- match). Writes are captured while CS is high and applied when CS falls.
-- Reads drive IO_DATA only while CS is high and IO_WRITE is low; a DONE flag
-- is cleared when the read cycle ends. CLOCK must be the same clock SCOMP
-- uses (or at least synchronous with CS).
--
-- Sangyun Lee, ECE 2031 L06

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY TimeKeeper IS
	GENERIC (
		CLK_FREQ : INTEGER := 12000000   -- frequency of CLOCK in Hz: SET THIS TO THE REAL CLOCK
	);
	PORT (
		CLOCK    : IN    STD_LOGIC;
		RESETN   : IN    STD_LOGIC;
		CS       : IN    STD_LOGIC;
		IO_WRITE : IN    STD_LOGIC;
		IO_ADDR  : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);   -- low 4 bits of IO_ADDR
		IO_DATA  : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0)
	);
END TimeKeeper;

ARCHITECTURE a OF TimeKeeper IS
	CONSTANT MS_DIV : INTEGER := CLK_FREQ / 1000;   -- clocks per 1 ms
	CONSTANT NCH    : INTEGER := 4;

	TYPE u16_array  IS ARRAY (0 TO NCH-1) OF UNSIGNED(15 DOWNTO 0);
	TYPE u10_array  IS ARRAY (0 TO NCH-1) OF UNSIGNED(9 DOWNTO 0);
	TYPE slv2_array IS ARRAY (0 TO NCH-1) OF STD_LOGIC_VECTOR(1 DOWNTO 0);

	TYPE sub_array  IS ARRAY (0 TO NCH-1) OF INTEGER RANGE 0 TO MS_DIV-1;
	SIGNAL sub     : sub_array;    -- clock counter inside one ms (per channel,
	                               -- so timing starts exactly at the write)

	SIGNAL count   : u16_array;    -- current count
	SIGNAL reload  : u16_array;    -- value last written (periodic reload)
	SIGNAL pre     : u10_array;    -- ms counter inside one unit
	SIGNAL mode    : slv2_array;
	SIGNAL unit    : slv2_array;
	SIGNAL pause   : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);
	SIGNAL bcd     : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);
	SIGNAL run     : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);
	SIGNAL done    : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);

	SIGNAL cs_d    : STD_LOGIC;
	SIGNAL wr_pend : STD_LOGIC;
	SIGNAL wr_addr : STD_LOGIC_VECTOR(3 DOWNTO 0);
	SIGNAL wr_data : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL rd_addr : STD_LOGIC_VECTOR(3 DOWNTO 0);
	SIGNAL rd_snap : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);  -- DONE flags SCOMP saw
	SIGNAL rd_data : STD_LOGIC_VECTOR(15 DOWNTO 0);

	-- binary to 4-digit BCD (double dabble); values above 9999 read as 9999
	FUNCTION to_bcd(v : UNSIGNED(15 DOWNTO 0)) RETURN STD_LOGIC_VECTOR IS
		VARIABLE b : UNSIGNED(15 DOWNTO 0) := (OTHERS => '0');
	BEGIN
		IF v > 9999 THEN
			RETURN x"9999";
		END IF;
		FOR i IN 15 DOWNTO 0 LOOP
			FOR d IN 0 TO 3 LOOP
				IF b(4*d+3 DOWNTO 4*d) > 4 THEN
					b(4*d+3 DOWNTO 4*d) := b(4*d+3 DOWNTO 4*d) + 3;
				END IF;
			END LOOP;
			b := b(14 DOWNTO 0) & v(i);
		END LOOP;
		RETURN STD_LOGIC_VECTOR(b);
	END to_bcd;

	-- last value of the ms counter inside one unit
	FUNCTION unit_last(u : STD_LOGIC_VECTOR(1 DOWNTO 0)) RETURN UNSIGNED IS
	BEGIN
		CASE u IS
			WHEN "00"   => RETURN to_unsigned(0, 10);     -- 1 ms
			WHEN "01"   => RETURN to_unsigned(9, 10);     -- 10 ms
			WHEN "10"   => RETURN to_unsigned(99, 10);    -- 100 ms
			WHEN OTHERS => RETURN to_unsigned(999, 10);   -- 1 s
		END CASE;
	END unit_last;

BEGIN

	-- ---------------- read data (combinational) ----------------
	PROCESS (IO_ADDR, count, bcd, done, run, pause)
		VARIABLE n : INTEGER RANGE 0 TO NCH-1;
	BEGIN
		n := to_integer(UNSIGNED(IO_ADDR(2 DOWNTO 1)));
		rd_data <= (OTHERS => '0');
		IF IO_ADDR(3) = '0' THEN
			IF IO_ADDR(0) = '0' THEN                     -- CHn_COUNT
				IF bcd(n) = '1' THEN
					rd_data <= to_bcd(count(n));
				ELSE
					rd_data <= STD_LOGIC_VECTOR(count(n));
				END IF;
			ELSE                                         -- CHn_CTRL: DONE flag
				rd_data(0) <= done(n);
			END IF;
		ELSIF IO_ADDR = "1000" THEN                      -- TK_STATUS
			rd_data(3 DOWNTO 0) <= done;
			rd_data(7 DOWNTO 4) <= run AND NOT pause;
		END IF;
	END PROCESS;

	IO_DATA <= rd_data WHEN (CS = '1' AND IO_WRITE = '0') ELSE (OTHERS => 'Z');

	-- ---------------- timing and bus writes ----------------
	PROCESS (CLOCK, RESETN)
		VARIABLE n      : INTEGER RANGE 0 TO NCH-1;
		VARIABLE d_next : STD_LOGIC_VECTOR(NCH-1 DOWNTO 0);
	BEGIN
		IF RESETN = '0' THEN
			FOR i IN 0 TO NCH-1 LOOP
				sub(i)    <= 0;
				count(i)  <= (OTHERS => '0');
				reload(i) <= (OTHERS => '0');
				pre(i)    <= (OTHERS => '0');
				mode(i)   <= "00";
				unit(i)   <= "00";
			END LOOP;
			pause   <= (OTHERS => '0');
			bcd     <= (OTHERS => '0');
			run     <= (OTHERS => '0');
			done    <= (OTHERS => '0');
			cs_d    <= '0';
			wr_pend <= '0';
			wr_addr <= (OTHERS => '0');
			wr_data <= (OTHERS => '0');
			rd_addr <= (OTHERS => '0');
			rd_snap <= (OTHERS => '0');

		ELSIF RISING_EDGE(CLOCK) THEN
			d_next := done;

			-- channel counting (each channel has its own ms and unit prescalers,
			-- so a channel started at any time gets full-length units)
			FOR i IN 0 TO NCH-1 LOOP
				IF run(i) = '1' AND pause(i) = '0' THEN
				  IF sub(i) /= MS_DIV-1 THEN
					sub(i) <= sub(i) + 1;
				  ELSE
					sub(i) <= 0;
					IF pre(i) = unit_last(unit(i)) THEN
						pre(i) <= (OTHERS => '0');
						IF mode(i)(1) = '1' THEN                 -- stopwatch
							IF count(i) /= x"FFFF" THEN
								count(i) <= count(i) + 1;
							END IF;
						ELSIF count(i) < 2 THEN                  -- countdown finished
							d_next(i) := '1';
							IF mode(i)(0) = '1' THEN             -- periodic: reload
								count(i) <= reload(i);
							ELSE                                 -- one-shot: stop at 0
								count(i) <= (OTHERS => '0');
								run(i)   <= '0';
							END IF;
						ELSE
							count(i) <= count(i) - 1;
						END IF;
					ELSE
						pre(i) <= pre(i) + 1;
					END IF;
				  END IF;
				END IF;
			END LOOP;

			-- bus: capture during the I/O cycle
			cs_d <= CS;
			IF CS = '1' THEN
				IF IO_WRITE = '1' THEN
					wr_pend <= '1';
					wr_addr <= IO_ADDR;
					wr_data <= IO_DATA;
				ELSE
					rd_addr <= IO_ADDR;
					rd_snap <= done;
				END IF;
			END IF;

			-- bus: act when the I/O cycle ends (bus actions override counting)
			IF cs_d = '1' AND CS = '0' THEN
				IF wr_pend = '1' THEN
					wr_pend <= '0';
					n := to_integer(UNSIGNED(wr_addr(2 DOWNTO 1)));
					IF wr_addr(3) = '0' THEN
						IF wr_addr(0) = '0' THEN                 -- CHn_COUNT
							count(n)  <= UNSIGNED(wr_data);
							reload(n) <= UNSIGNED(wr_data);
							pre(n)    <= (OTHERS => '0');
							sub(n)    <= 0;
							d_next(n) := '0';
							IF mode(n)(1) = '1' OR wr_data /= x"0000" THEN
								run(n) <= '1';
							ELSE
								run(n) <= '0';
							END IF;
						ELSE                                     -- CHn_CTRL
							mode(n)  <= wr_data(1 DOWNTO 0);
							unit(n)  <= wr_data(3 DOWNTO 2);
							pause(n) <= wr_data(4);
							bcd(n)   <= wr_data(5);
							IF wr_data(3 DOWNTO 2) /= unit(n) THEN   -- keep partial unit on pause/resume
								pre(n) <= (OTHERS => '0');
								sub(n) <= 0;
							END IF;
						END IF;
					END IF;
				ELSE                                             -- a read ended
					IF rd_addr(3) = '0' AND rd_addr(0) = '1' THEN
						n := to_integer(UNSIGNED(rd_addr(2 DOWNTO 1)));
						IF rd_snap(n) = '1' THEN
							d_next(n) := '0';
						END IF;
					ELSIF rd_addr = "1000" THEN
						d_next := d_next AND NOT rd_snap;
					END IF;
				END IF;
			END IF;

			done <= d_next;
		END IF;
	END PROCESS;

END a;
