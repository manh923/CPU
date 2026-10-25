MyCPU README
============
This computer runs on a homemade CPU with a homemade instruction set:
32/64-bit, no flags, 1-bit predicate registers, little endian.

Drive C: is a microSD card (FAT16 or FAT32, read-only for now).
Put files in the root directory from your PC and they show up in DIR.

Programs
  HELLO.EXE   Says hello. Try HELLO yourname.
  FIB.EXE     Fibonacci numbers. Try FIB 40.
  MANDEL.EXE  The Mandelbrot set in color.
  KITT.COM    Runs the board LEDs back and forth.
  DEMO.BAT    A batch file that runs some of the above.

Make your own: write it with .org 0x23000, then tools/mkdisk.js turns
NAME.exe.asm into NAME.EXE (or NAME.com.asm into NAME.COM).
