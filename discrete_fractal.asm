global _start

SYS_EXIT equ 60
SYS_READ equ 0
SYS_BRK equ 12
SUCCESS_EXIT_CODE equ 0
ERROR_EXIT_CODE equ 1

_start:
    pop         rdi                     ; Get parameter count
    cmp         rdi, 2                  ; Expect program name and iteration count
    jnz         .error

    mov         rax, SYS_BRK 
    xor         edi, edi
    syscall                             ; Get current heap start 

    mov         eax, SYS_EXIT
    xor         edi, edi
    syscall

.error:
    mov         eax, SYS_EXIT
    mov         edi, ERROR_EXIT_CODE
    syscall
