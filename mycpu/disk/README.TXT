MyCPU README
============
This computer runs on a homemade CPU with a homemade instruction set:
32/64-bit, no flags, 1-bit predicate registers, little endian.

The ROM holds only the BIOS. It loads MYDOS.SYS from this SD card
(FAT16 or FAT32), just like a real PC loads DOS from a disk.

Programs run in user mode and talk to MyDOS with SYSCALL (like INT 21h).
If a program crashes, MyDOS stops it and comes back to C:\>.
Programs may use the 8 MB SDRAM (0x1000000-0x17FFFFF) freely.

Programs
  HELLO.EXE    Says hello. Try HELLO yourname.
  FIB.EXE      Fibonacci numbers. Try FIB 40.
  MANDEL.EXE   The Mandelbrot set in color.
  KITT.COM     Runs the board LEDs back and forth.
  TOUPPER.EXE  TOUPPER README.TXT UP.TXT writes an upper-case copy.
  SIEVE.EXE    Counts primes below 1,000,000 using 1 MB of SDRAM.
  BIG.EXE      Runs from SDRAM (with its stack there too).
  CRASH.EXE    Divides by zero on purpose.
  DEMO.BAT     A batch file that runs some of the above.
  PRIMES.EXE   Prime numbers (written in C).
  EDIT.EXE     A full-screen text editor. EDIT NOTE.TXT (Ctrl-S, Ctrl-X).

The C compiler is on this card too:
  CC.EXE       chibicc, compiled for this CPU. CC FILE.C writes FILE.S.
  AS.EXE       The assembler. Links FILE.S with CRT0.S and LIBC.S.
  BUILD.BAT    BUILD NAME = CC NAME.C, then AS. Makes NAME.EXE.
  Try: EDIT HI.C, write a main(), BUILD HI, then HI.
  The headers (STDIO.H ...) and chibicc's own source are here as well.

Try writing: COPY CON NOTE.TXT, DIR > LIST.TXT, REN, DEL.

Or in assembly: write it with .org 0x26000 (or .org 0x1000000 for a
big .EXE in SDRAM), then tools/mkdisk.js turns
NAME.exe.asm into NAME.EXE (or NAME.com.asm into NAME.COM).
