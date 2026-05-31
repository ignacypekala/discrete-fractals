global _start

SYS_EXIT                equ 60
SYS_READ                equ 0
SYS_BRK                 equ 12
SYS_MMAP                equ 9
SYS_MREMAP              equ 25

PROT_READ               equ 0x1
PROT_WRITE              equ 0x2
MAP_PRIVATE             equ 0x02
MAP_ANONYMOUS           equ 0x20
MREMAP_MAYMOVE          equ 0x1

READ_ERROR              equ -1
MAP_FAILED              equ -1
EOF                     equ 0

STD_IN                  equ 0
STD_OUT                 equ 1

LINE_BREAK              equ 10
ASCII_START             equ 33
ASCII_END               equ 126

INITIAL_BUFFER_SIZE             equ 4096
RULE_REGISTRY_ENTRY_SIZE        equ 16                  ; base pointer + rule length
RULE_REGISTRY_TOTAL_SIZE        equ (ASCII_END - ASCII_START) * RULE_REGISTRY_ENTRY_SIZE

PARAMETER_COUNT         equ 2                           ; program name + iteration count
ERROR_CODE              equ 1

; Allocate a block of memory.
;  %1 - error jump label
;  %2 - address hint
%macro MALLOC 2
    mov                 rax, SYS_MMAP
    mov                 edi, %2                         ; address hint
    mov                 rsi, INITIAL_BUFFER_SIZE
    mov                 edx, PROT_READ | PROT_WRITE
    mov                 r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov                 r8, -1                          ; file descriptor
    xor                 r9, r9                          ; offset
    syscall
    test            rax, rax
    js                  %1
%endmacro

; Reallocates a block of memory to twice its size. Updates the base address on success.
;  %1 - original address
;  %2 - original size
;  %3 - error jump label
;  %4 - address hint
%macro REALLOC 4
    mov                 rax, SYS_MREMAP
    mov                 rdi, %1                         ; original address
    mov                 rsi, %2                         ; original size
    mov                 rdx, rsi
    shl                 rdx, 1                          ; new size
    mov                 r10, MREMAP_MAYMOVE
    mov                 r8, %4
    syscall
    test                rax, rax
    js                  %3
    mov                 %1, rax                         ; update address
    mov                 %2, rdx                         ; update size
%endmacro

; Read from standard input.
;  %1 - base address
;  %2 - offset
;  %3 - buffer size
;  %5 - eof jump label
%macro READ 4
    mov                 rax, SYS_READ
    xor                 edi, edi                        ; stdin
    lea                 rsi, [%1 + %2]                  ; address
    mov                 rdx, %3
    sub                 rdx, %2                         ; count
    syscall
    test                rax, rax
    js                  %4
%endmacro

; Scan a buffer to find the first occurance of a line break. In the process ensure all of the
; characters are in the allowed range. Overwrites rcx, rax and r11. The position of the
; linebreak relative to the designated offset is stored in rcx. If the line break was found register
; al contains a line break.
;  %1 - base address
;  %2 - offset
;  %3 - read length limit
;  %4 - invalid character jump label
%macro SCAN_LINE 4
    lea                 rcx, [%1 + %2]                  ; start pointer
    lea                 r11, [rcx + %3]                  ; end pointer
    xor                 eax, eax                        ; clear al

%%scan_character:
    cmp                 rcx, r11
    jz                  %%return                        ; eof

    mov                 al, [rcx]                       ; byte to check
    cmp                 al, LINE_BREAK
    je                  %%return                        ; line break found
    cmp                 al, ASCII_START
    jb                  %4                              ; invalid character
    cmp                 al, ASCII_END
    ja                  %4                              ; invalid character

    inc                 rcx
    jmp                 %%scan_character

%%return:
    ; Convert the line break pointer to its position relative to the offset.
    sub                 rcx, %1
    sub                 rcx, %2
%endmacro

section .bss

string_buffer_pointer:  resq 1
string_buffer_size:     resq 1
string_buffer_offset:   resq 1

rules_buffer_pointer:   resq 1
rules_buffer_size:      resq 1
rules_buffer_offset:    resq 1

rules_registry:         resb RULE_REGISTRY_TOTAL_SIZE

section .text

_start:
    ; Validate parameter count.
    pop                 rdi
    cmp                 rdi, PARAMETER_COUNT
    jnz                 .error_exit

    ; Allocate string buffer.
    ; TODO: Manage the address hints
    MALLOC              .error_exit, 0

    ; Initialize the string buffer state.
    mov                 rbp, rax                        ; base address
    mov                 r14, INITIAL_BUFFER_SIZE        ; total size
    xor                 r12, r12                        ; current offset

.load_string_chunk:
    READ                rbp, r12, r14, .free_string_buffer_and_quit
    
    ; Register r12 holds a stale value - the offset start of the last read.
    mov                 r13, rax                        ; Save the new number of bytes read.

    ; Check if the entire first line has been loaded.
    SCAN_LINE           rbp, r12, r13, .free_string_buffer_and_quit
    cmp                 al, LINE_BREAK
    je                  .copy_rules_from_string_buffer  ; line break found

    add                 r12, r13                        ; Update the string buffer offset.

    cmp                 r13, rdx
    jl                  .free_string_buffer_and_quit    ; The input ended before the first line break.

    ; Reallocate the string buffer
    REALLOC             rbp, r14, .free_string_buffer_and_quit, 0

    jmp                 .load_string_chunk

.copy_rules_from_string_buffer:
    ; rcx - the number of bytes from the very last read, which are a part of the first line.

    ; Update the string buffer offset.
    add                 r12, rcx

    ; Save length of the preloaded rules (bytes read - (line break position + 1)).
    lea                 r15, [r13 - 1]
    sub                 r15, rcx

    ; Allocate rules buffer.
    MALLOC              .free_string_buffer_and_quit, 0

    ; Check if there are any preloaded rules to copy.
    test                r15, r15
    jz                  .load_rules

    ; Copy the first batch of rules from the string buffer.
    mov                 rcx, r15                        ; length
    lea                 rsi, [rbp + r12 + 1]            ; start of preloaded rules in input buffer
    mov                 rdi, rax                        ; rules buffer
    rep                 movsb

.load_rules:
    ; rules buffer state:
    ;   rbx - base address
    ;   r13 - total size
    ;   r15 - current offset
    mov                 rbx, rax
    mov                 r13, INITIAL_BUFFER_SIZE

.load_rules_chunk:
    READ                rbx, r15, r13, .free_both_buffers_and_quit
    add                 r15, rax                        ; move the offset
    cmp                 rax, rdx
    jl                  .build_rules_registry           ; all rules loaded

    ; Increase the buffer and load more rules.
    REALLOC             rbx, r13, .free_both_buffers_and_quit, 0
    jmp                 .load_rules_chunk

.build_rules_registry:
    xor                 rdx, rdx                        ; rules buffer offset
    lea                 r9, [rel rules_registry]

.register_rule:
    SCAN_LINE           rbx, rdx, r15, .free_both_buffers_and_quit
    cmp                 al, LINE_BREAK
    jne                 .free_both_buffers_and_quit     ; unterminated line
    mov                 al, [rbx + rdx]                       ; Extract rule character.

    ; Save rule info to the registry.
    lea                 r11, [rbx + rdx]
    mov                 [r9], r11                       ; start pointer
    mov                 [r9 + 8], rcx                   ; length

    add                 rdx, rcx                        ; Advance the rules buffer offset.
    inc                 rdx                             ; first character after the line break
    add                 r9, RULE_REGISTRY_ENTRY_SIZE
    cmp                 rdx, r15
    jl                  .register_rule                  ; There still are rules to register.

    mov                 eax, SYS_EXIT
    xor                 edi, edi
    syscall

.free_both_buffers_and_quit:
    ; TODO: Free the rules buffer.
    nop

.free_string_buffer_and_quit:
    ; TODO: Free the input buffer.
    nop

.error_exit:
    mov                 eax, SYS_EXIT
    mov                 edi, ERROR_CODE
    syscall
