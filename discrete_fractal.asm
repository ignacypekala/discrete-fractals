global _start

SYS_EXIT        equ 60
SYS_READ        equ 0
SYS_BRK         equ 12
SYS_MMAP        equ 9
SYS_MREMAP      equ 25

PROT_READ       equ 0x1
PROT_WRITE      equ 0x2
MAP_PRIVATE     equ 0x02
MAP_ANONYMOUS   equ 0x20
MREMAP_MAYMOVE  equ 0x1

READ_ERROR      equ -1
MAP_FAILED      equ -1
EOF             equ 0

STD_IN          equ 0
STD_OUT         equ 1

INITIAL_BUFFER_SIZE         equ 4096

LINE_BREAK      equ 10

PARAMETER_COUNT equ 2                           ; program name + iteration count
ERROR_CODE      equ 1

; Allocate a block of memory.
; %1 - error jump label
; %2 - address hint
%macro malloc 2
    mov         rax, SYS_MMAP
    mov         edi, %2                         ; address hint
    mov         rsi, INITIAL_BUFFER_SIZE
    mov         edx, PROT_READ | PROT_WRITE
    mov         r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov         r8, -1                          ; file descriptor
    xor         r9, r9                          ; offset
    syscall
    test        rax, rax
    js          %1
%endmacro

; Realloc a block to twice its size.
; %1 - original address
; %2 - original size
; %3 - error jump label
; %4 - address hint
%macro realloc 4
    mov         rax, SYS_MREMAP
    mov         rdi, %1                         ; original address
    mov         rsi, %2                         ; original size
    mov         rdx, rsi
    shl         rdx, 1                          ; new size
    mov         r10, MREMAP_MAYMOVE
    mov         r8, %4
    syscall
    test        rax, rax
    js          %3
    mov         %1, rax                         ; update address
    mov         %2, rdx                         ; update size
%endmacro

; Read from standard input.
; %1 - base address
; %2 - offset
; %3 - buffer size
; %4 - read error jump label
%macro read 4
    mov         rax, SYS_READ
    xor         edi, edi                        ; stdin
    lea         rsi, [%1 + %2]                  ; address
    mov         rdx, %3
    sub         rdx, %2                         ; offset
    syscall
    test        rax, rax
    js          %4
%endmacro

_start:
    ; Validate parameter count.
    pop         rdi
    cmp         rdi, PARAMETER_COUNT
    jnz         .error_exit

    ; Allocate string buffer.
    ; TODO: Manage the address hints
    malloc      .error_exit, 0

    ; Initialize the string buffer state.
    mov         r14, rax                        ; base address
    mov         r10, INITIAL_BUFFER_SIZE        ; total size
    xor         r12, r12                        ; current offset

.load_string_chunk:
    read        r14, r12, r10, .free_string_buffer_and_quit
    
    ; Register r12 holds a stale value - the offset start of the last read.
    mov         r13, rax                        ; Save the new number of bytes read.

    ; Check if the entire first line has been loaded.
    mov         rcx, r13                        ; the number of bytes read
    lea         rdi, [r14 + r12]                ; the start of last read chunk
    mov         al, LINE_BREAK
    ; TODO: Evaluate the manual alternative to repne scasb.
    repne       scasb                           ; Try to find the line break.
    jz          .copy_rules_from_string_buffer       ; The line break has been found.

    add         r12, r13                        ; Update the string buffer offset.

    ; Reallocate the string buffer
    realloc     r14, r10, .free_string_buffer_and_quit, 0

    jmp .load_string_chunk

.copy_rules_from_string_buffer:
    ; Update the string buffer offset.
    add         r12, r13                        ; number of bytes read
    sub         r12, rcx                        ; length of preloaded rules

    ; Save the preloaded rules info.
    mov         r13, rdi                        ; start offset
    mov         r15, rcx                        ; length

    ; Allocate rules buffer.
    malloc      .free_string_buffer_and_quit, 0

    ; Check if there are any preloaded rules to copy.
    cmp         r15, r15
    jz          .load_rules_chunk

    ; Copy the first batch of rules from the string buffer.
    mov         rcx, r15                        ; length
    mov         rsi, r14                        ; string buffer
    mov         rdi, rax                        ; rules buffer
    rep         movsb

    ; Rules buffer state:
    ;   rbp - base address
    ;   r13 - total size
    ;   r15 - current offset
    mov         rbp, rax
    mov         r13, INITIAL_BUFFER_SIZE

.load_rules_chunk:
    read        rbp, r15, r13, .free_both_buffers_and_quit

    ; TODO Reallocate the buffer

    mov         eax, SYS_EXIT
    xor         edi, edi
    syscall

.free_both_buffers_and_quit:
    ; TODO: Free the rules buffer.

.free_string_buffer_and_quit:
    ; TODO: Free the input buffer.

.error_exit:
    mov         eax, SYS_EXIT
    mov         edi, ERROR_CODE
    syscall
