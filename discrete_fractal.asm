global _start

SYS_EXIT equ 60
SYS_READ equ 0
SYS_BRK equ 12
SUCCESS_EXIT_CODE equ 0
ERROR_EXIT_CODE equ 1

_start:
    
    ; Validate parameter count (program name + iteration count)
    pop         rdi
    cmp         rdi, 2
    jnz         .error

    ; Get current heap start 
    mov         rax, SYS_BRK 
    xor         edi, edi
    syscall                             

    mov         eax, SYS_EXIT
    xor         edi, edi
    syscall

.error:
    mov         eax, SYS_EXIT
    mov         edi, ERROR_EXIT_CODE
    syscall
