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

_start:
    ; Validate parameter count.
    pop         rdi
    cmp         rdi, PARAMETER_COUNT
    jnz         .error_exit

    ; Allocate the string buffer
    ; TODO: Manage the address hints
    mov         rax, SYS_MMAP
    xor         edi, edi                        ; address hint
    mov         esi, INITIAL_BUFFER_SIZE
    mov         edx, PROT_READ | PROT_WRITE
    mov         r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov         r8, -1                          ; file descriptor
    xor         r9, r9                          ; offset
    syscall
    cmp         rax, MAP_FAILED
    jz          .error_exit

    ; Initialize the string buffer state
    mov         r14, rax                        ; base address
    mov         r10, INITIAL_BUFFER_SIZE        ; total size
    xor         r12, r12                        ; current offset

.load_initial_string_chunk:
    mov         rax, SYS_READ
    xor         edi, edi                        ; STD_IN
    lea         rsi, [r14 + r12]                ; the free part of the buffer
    mov         rdx, r10
    sub         rdx, r12                        ; the size of the empty space
    syscall
    test         rax, rax
    js          .free_string_buffer_and_quit

    ; As of now the register r12 holds a stale value but it will be needed for input processing.
    mov         r13, rax                        ; Save the new number of bytes read.

    test        rax, rax
    jz          .free_string_buffer_and_quit    ; The input ended before the first line break.
    
    ; Check if the entire first line has been loaded.
    mov         rcx, r13                        ; the number of bytes read
    lea         rdi, [r14 + r12]                ; the start of last read chunk
    mov         al, LINE_BREAK
    repne       scasb
    jz          .extract_rules_from_string_buffer       ; The line break has been found.

    ; Reallocate the string buffer
    mov         rax, SYS_MREMAP
    mov         rdi, r14                        ; string buffer address
    mov         rsi, r10                        ; string buffer size
    mov         rdx, rsi
    shl         rdx, 1                          ; new size
    mov         r10, MREMAP_MAYMOVE
    xor         r8,  r8                         ; new address hint
    syscall
    test        rax, rax
    js          .free_string_buffer_and_quit    ; User space addresses are always positive.

    ; Update the buffer address, size and offset.
    mov         r14, rax
    mov         r10, rdx
    add         r12, r13

    jmp .load_initial_string_chunk

.extract_rules_from_string_buffer:
    ; rdi holds the address of the first byte of the rules (provided there are any).
    ; rcx holds the length of the loaded rules.

    ; Allocate the rules buffer
    mov         rax, SYS_MMAP
    xor         edi, edi                        ; address hint
    mov         esi, INITIAL_BUFFER_SIZE
    mov         edx, PROT_READ | PROT_WRITE
    mov         r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov         r8, -1                          ; file descriptor
    xor         r9, r9                          ; offset
    syscall
    cmp         rax, MAP_FAILED
    jz          .free_string_buffer_and_quit

.load_remaining_rules:
    ; TODO: Load remaining rules

    mov         eax, SYS_EXIT
    xor         edi, edi
    syscall

.free_string_buffer_and_quit:
    ; TODO: Free the input buffer
    
.error_exit:
    mov         eax, SYS_EXIT
    mov         edi, ERROR_CODE
    syscall
