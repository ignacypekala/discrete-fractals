global _start

SYS_EXIT        equ 60
SYS_READ        equ 0
SYS_BRK         equ 12
SYS_MMAP        equ 9
SYS_MREMAP      equ 25

PROT_READ       equ 0x1
PROT_WRITE      equ 0x2
MAP_PRIVATE     equ 0x01
MAP_ANONYMOUS   equ 0x20

READ_ERROR      equ -1
MAP_FAILED      equ -1
EOF             equ 0

STD_IN          equ 0
STD_OUT         equ 1

INITIAL_BUFFER_SIZE         equ 4096
INITIAL_BUFFER_SIZE_HALF    equ 2048

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

    mov         r11, rax                         ; string buffer address
    mov         r10, INITIAL_BUFFER_SIZE_HALF

.load_initial_string_chunk:
    mov         rax, SYS_READ
    mov         edi, STD_IN
    lea         rsi, [r11 + r10]                 ; the free half of the buffer
    mov         rdx, r10                        ; the size of the empty half
    syscall
    cmp         rax, READ_ERROR
    jz          .free_string_buffer_and_quit

    test        rax, rax
    jz          .free_string_buffer_and_quit      ; The input ended before the first line break.

    ; Check if the first line has been loaded completely
    mov         rcx, rax                        ; the number of bytes read
    lea         rdi, [r11 + r10]                 ; the start of last read chunk
    mov         al, LINE_BREAK
    repne       scasb
    jz          .extract_rules_from_string_buffer       ; The line break has been found.

    ; Increase the buffer size
    shl         r10, 1

    ; Reallocate the string buffer
    mov         rax, SYS_MREMAP
    xor         rdi, r11                         ; string buffer address
    mov         rsi, r10                        ; string buffer size
    mov         rdi, rsi
    shl         rdi, 1                          ; new size
    mov         edi, MAP_PRIVATE | MAP_ANONYMOUS
    xor         r8,  r8                         ; new address hint
    syscall
    test        rax, rax
    jz          .free_string_buffer_and_quit
    mov         r11, rax

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
