; SlotMachine.asm
; Demo program for the TimeKeeper peripheral (ECE 2031 project)
; Based on my earlier slot-machine digital sign.
;
;  - Raise SW9 to start a round.
;  - Three number reels spin on Hex0 (digits 2..0). Each reel steps on its own
;    TimeKeeper channel in periodic mode, so each reel has its own speed.
;    The left and right reels count up, the center reel counts down.
;  - SW0, SW1, SW2 stop the left, center, and right reels.
;  - Channel 3 counts down a 10-second round in seconds. It is read in BCD,
;    so Hex1 shows the time left in decimal (10, 09, ... 00).
;  - The round ends when all three reels are stopped or time runs out.
;    The clock is paused, so Hex1 keeps the time left as the score.
;  - Three equal digits = jackpot: the LEDs blink every 250 ms.
;  - Lower all switches to get ready for the next round.
;
; Sangyun Lee, ECE 2031 L06

        ORG     0
Start:
        LOADI   0
        OUT     LEDs
WaitDown:                       ; all switches down first
        IN      Switches
        JNZ     WaitDown
WaitGo:                         ; then SW9 starts the round
        IN      Switches
        AND     MaskSW9
        JZERO   WaitGo

        ; ---- configure TimeKeeper ----
        LOADI   CfgPeriodicMs
        OUT     T0_CTRL
        OUT     T1_CTRL
        OUT     T2_CTRL
        LOADI   CfgSecBCD
        OUT     T3_CTRL

        LOADI   1               ; starting digits 1, 5, 9
        STORE   Reel0
        LOADI   5
        STORE   Reel1
        LOADI   9
        STORE   Reel2
        LOADI   0
        STORE   Stopped         ; bit n = reel n stopped

        LOADI   Period0         ; start the reels
        OUT     T0_COUNT
        LOADI   Period1
        OUT     T1_COUNT
        LOADI   Period2
        OUT     T2_COUNT
        LOADI   RoundSec        ; start the round clock
        OUT     T3_COUNT

Spin:
        ; reel 0 (left) counts up when its period has elapsed
        IN      T0_CTRL         ; 1 once per period; reading clears it
        JZERO   Reel1Chk
        LOAD    Reel0
        ADDI    1
        STORE   Reel0
        ADDI    -10
        JNEG    Reel1Chk
        STORE   Reel0           ; 10 -> 0
Reel1Chk:
        ; reel 1 (center) counts down
        IN      T1_CTRL
        JZERO   Reel2Chk
        LOAD    Reel1
        ADDI    -1
        STORE   Reel1
        JPOS    Reel2Chk
        JZERO   Reel2Chk
        LOADI   9               ; -1 -> 9
        STORE   Reel1
Reel2Chk:
        ; reel 2 (right) counts up
        IN      T2_CTRL
        JZERO   Display
        LOAD    Reel2
        ADDI    1
        STORE   Reel2
        ADDI    -10
        JNEG    Display
        STORE   Reel2
Display:
        CALL    ShowReels
        IN      T3_COUNT        ; seconds left, already BCD
        OUT     Hex1

        ; ---- stop switches ----
        IN      Switches
        AND     MaskSW0
        JZERO   Stop1
        LOADI   0
        OUT     T0_COUNT        ; writing 0 stops a periodic channel
        LOAD    Stopped
        OR      MaskSW0
        STORE   Stopped
Stop1:
        IN      Switches
        AND     MaskSW1
        JZERO   Stop2
        LOADI   0
        OUT     T1_COUNT
        LOAD    Stopped
        OR      MaskSW1
        STORE   Stopped
Stop2:
        IN      Switches
        AND     MaskSW2
        JZERO   EndChk
        LOADI   0
        OUT     T2_COUNT
        LOAD    Stopped
        OR      MaskSW2
        STORE   Stopped
EndChk:
        LOAD    Stopped
        XOR     AllReels
        JZERO   RoundOver       ; all three reels stopped
        IN      T3_CTRL         ; 10 s up?
        JZERO   Spin

RoundOver:
        LOADI   0               ; stop every reel
        OUT     T0_COUNT
        OUT     T1_COUNT
        OUT     T2_COUNT
        LOADI   CfgSecBCDPause  ; freeze the clock: time left = score
        OUT     T3_CTRL
        CALL    ShowReels
        IN      T3_COUNT
        OUT     Hex1

        LOAD    Reel0           ; jackpot if all digits are equal
        SUB     Reel1
        JNZ     NoWin
        LOAD    Reel1
        SUB     Reel2
        JNZ     NoWin

Jackpot:
        LOADI   CfgPeriodicMs   ; reuse channel 0 to blink the LEDs
        OUT     T0_CTRL
        LOADI   BlinkMs
        OUT     T0_COUNT
        LOADI   0
        STORE   LedPat
Blink:
        IN      T0_CTRL
        JZERO   BlinkSw
        LOAD    LedPat
        XOR     AllLeds
        STORE   LedPat
        OUT     LEDs
BlinkSw:
        IN      Switches
        JNZ     Blink           ; blink until all switches are down
        LOADI   0
        OUT     T0_COUNT
        JUMP    Start

NoWin:
        IN      Switches
        JNZ     NoWin
        JUMP    Start

; ShowReels: Hex0 = 0, Reel0, Reel1, Reel2 (one digit per nibble)
ShowReels:
        LOAD    Reel0
        SHIFT   4
        OR      Reel1
        SHIFT   4
        OR      Reel2
        OUT     Hex0
        RETURN

; ---- variables ----
Reel0:    DW    0
Reel1:    DW    0
Reel2:    DW    0
Stopped:  DW    0
LedPat:   DW    0

; ---- constants in memory (for AND/OR/XOR) ----
MaskSW0:  DW    &H001
MaskSW1:  DW    &H002
MaskSW2:  DW    &H004
MaskSW9:  DW    &H200
AllReels: DW    &H007
AllLeds:  DW    &H3FF

; ---- immediates ----
Period0:        EQU  80     ; ms per step, left reel
Period1:        EQU  110    ; ms per step, center reel
Period2:        EQU  140    ; ms per step, right reel
RoundSec:       EQU  10     ; round length in seconds
BlinkMs:        EQU  250
CfgPeriodicMs:  EQU  &B000001   ; periodic, 1 ms units
CfgSecBCD:      EQU  &B101100   ; one-shot, 1 s units, BCD read
CfgSecBCDPause: EQU  &B111100   ; same, paused

; ---- I/O addresses ----
Switches: EQU   &H000
LEDs:     EQU   &H001
Hex0:     EQU   &H004
Hex1:     EQU   &H005
T0_COUNT: EQU   &H0F0       ; TimeKeeper base = &H0F0 (change if the team picks another)
T0_CTRL:  EQU   &H0F1
T1_COUNT: EQU   &H0F2
T1_CTRL:  EQU   &H0F3
T2_COUNT: EQU   &H0F4
T2_CTRL:  EQU   &H0F5
T3_COUNT: EQU   &H0F6
T3_CTRL:  EQU   &H0F7
TK_STATUS: EQU  &H0F8
