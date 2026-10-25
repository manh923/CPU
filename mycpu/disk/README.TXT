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
  CRASH.EXE    Divides by zero on purpose.
  DEMO.BAT     A batch file that runs some of the above.

Try writing: COPY CON NOTE.TXT, DIR > LIST.TXT, REN, DEL.

Make your own: write it with .org 0x26000, then tools/mkdisk.js turns
NAME.exe.asm into NAME.EXE (or NAME.com.asm into NAME.COM).
