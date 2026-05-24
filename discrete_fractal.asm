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

PARAMETER_COUNT equ 2                           ; program name + iteration count
ERROR_CODE      equ 1

_start:
    ; Validate parameter count.
    pop         rdi
    cmp         rdi, PARAMETER_COUNT
    jnz         .error

    ; Allocate the string buffer
    mov         rax, SYS_MMAP
    xor         edi, edi                          ; address hint
    mov         esi, INITIAL_BUFFER_SIZE
    mov         edx, PROT_READ | PROT_WRITE
    mov         r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov         r8, -1                          ; file descriptor
    xor         r9, r9                          ; offset
    syscall
    cmp         rax, MAP_FAILED
    jz          .error

    mov         r9, rax                         ; string buffer address
    mov         r10, INITIAL_BUFFER_SIZE_HALF

.load_initial_string_chunk:
    mov         rax, SYS_READ
    mov         edi, STD_IN
    lea         rsi, [r9 + r10]                 ; the free half of the buffer
    mov         rdx, r10                        ; the size of it
    syscall
    cmp         rax, READ_ERROR
    jz          .input_error
    cmp         rax, r10
    jb          .input_loaded                   ; All the input was read.

    ; Reallocate the string buffer
    mov rax, SYS_MREMAP
    xor         rdi, r9                         ; address
    mov         rsi, r10                        ; old length
    mov         rdi, rsi
    shl         rdi, 1                          ; new length
    mov         edi, MAP_PRIVATE | MAP_ANONYMOUS
    xor         r8, r8                          ; new address hint

.input_loaded:

    mov         eax, SYS_EXIT
    xor         edi, edi
    syscall

.input_error:
    ; TODO: Free the input buffer
    
.error:
    mov         eax, SYS_EXIT
    mov         edi, ERROR_CODE
    syscall
