ASM = nasm
ASMFLAGS = -f elf64 -w+all -w+error -w-unknown-warning -w-reloc-rel
LD = ld
LDFLAGS = -pie -I /lib64/ld-linux-x86-64.so.2 --fatal-warnings

ASMFLAGS += -g
LDFLAGS += -g

.PHONY: clean all

all: discrete_fractal

discrete_fractal.o: discrete_fractal.asm
	$(ASM) $(ASMFLAGS) -o $@ $<

discrete_fractal: discrete_fractal.o
	$(LD) $(LDFLAGS) -o $@ $<

clean:
	rm -f *.o discrete_fractal
