@ECHO [1/2] CC: compiling %1.C into %1.S
@CC %1.C
@ECHO [2/2] AS: assembling %1.S, linking C library into %1.EXE
@AS -lib \LIB\LIBC -o %1.EXE \LIB\CRT0.S %1.S
@ECHO Done.
