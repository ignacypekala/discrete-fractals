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

;
; Allocate INITIAL_BUFFER_SIZE bytes of anonymous memory via sys_mmap. Jump to %1 on failure.
;
; Parameters:
;  %1 - error jump label,
;  %2 - address hint.
;
; Affected registers:
;  rax - pointer to the allocated block (or negative error code after jump)
;  rdi - address hint
;  rsi - buffer size
;  rdx - protection flags
;  r10 - map flags
;  r8  - -1
;  r9  - 0
;  rcx, r11 - clobbered by syscall
;
%macro MALLOC 2
    mov                 rax, SYS_MMAP
    mov                 rdi, %2                         ; address hint
    mov                 rsi, INITIAL_BUFFER_SIZE
    mov                 edx, PROT_READ | PROT_WRITE
    mov                 r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov                 r8, -1                          ; file descriptor
    xor                 r9, r9                          ; offset
    syscall
    test                rax, rax
    js                  %1
%endmacro

;
; Reallocate a block of memory, doubling its size via sys_mremap. Jump to a designated label on
; allocation failure. Overwrite the provided address and size operands upon success.
;
; Parameters:
;  %1 - original address
;  %2 - original size
;  %3 - error jump label
;
; Affected registers:
;  rax - pointer to the reallocated block (or negative error code after jump)
;  rdi - original address
;  rsi - original size
;  rdx - new size (%2 * 2)
;  r10 - mremap flags
;  rcx, r11 - clobbered by syscall
;
%macro REALLOC 3
    mov                 rax, SYS_MREMAP
    mov                 rdi, %1                         ; original address
    mov                 rsi, %2                         ; original size
    mov                 rdx, rsi
    shl                 rdx, 1                          ; new size
    mov                 r10, MREMAP_MAYMOVE
    syscall
    test                rax, rax
    js                  %3
    mov                 %1, rax                         ; update address
    mov                 %2, rdx                         ; update size
%endmacro

;
; Read data from stdin into a buffer. Jump to a designated label on read errors.
;
; Parameters:
;  %1 - base address
;  %2 - offset
;  %3 - total buffer size
;  %4 - error jump label
;
; Affected registers:
;  rax - number of bytes read (or negative error code before jump)
;  rdi - 0
;  rsi - buffer write start pointer (%1 + %2)
;  rdx - maximum bytes to read (%3 - %2)
;  rcx, r11 - clobbered by syscall
;
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

;
; Scan a buffer for the first occurrence of a line break, ensuring all characters 
; are within an allowed range during the process. Jump to a designated label if 
; an invalid character is encountered.
;
; Parameters:
;  %1 - base address
;  %2 - offset
;  %3 - read length limit
;  %4 - invalid character jump label
;
; Affected registers (on normal return):
;  rax - al contains the line break character, or 0 if the read limit was reached.
;  rcx - number of bytes scanned (index of the line break, or exactly %3 if limit reached)
;  r11 - end of buffer pointer (%1 + %2 + %3)
;
; Affected registers (on jump to %4):
;  rax - al contains the invalid character that triggered the jump.
;  rcx - absolute memory pointer to the invalid character
;
%macro SCAN_LINE 4
    lea                 rcx, [%1 + %2]                  ; start pointer
    lea                 r11, [rcx + %3]                 ; end pointer
    xor                 eax, eax                        ; prepare al for the scanned byte

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

;
; Registers:
;  Volatile:
;   rax, rdi, rsi, rdx, r10, r8, r9 - syscall parameters or localized scratchpads
;   rcx, r11 - localized scratchpads often clobbered by syscalls
;  Buffer states:
;   rbp, rbx - base pointers
;   r12, r13 - total sizes
;   r14, r15 - offsets
;

_start:
    ; Validate parameter count.
    pop                 rax
    cmp                 rax, PARAMETER_COUNT
    jnz                 .error_exit

    ; Allocate string buffer.
    ; TODO: Manage the address hints
    MALLOC              .error_exit, 0

    ; Initialize the string buffer state.
    mov                 rbp, rax                        ; base address
    mov                 r12, INITIAL_BUFFER_SIZE        ; total size
    xor                 r14, r14                        ; current offset

.load_string_chunk:
    READ                rbp, r14, r12, .free_string_buffer_and_quit
    
    ; For now, register r14 will hold a stale value - the offset of the beginning of the last read.
    ; Note: r15 temporarily holds the last read size, violating its declared purpose. It will enter a
    ; legal state before building the rules buffer.
    mov                 r15, rax

    ; Check if the entire first line has been loaded.
    SCAN_LINE           rbp, r14, r15, .free_string_buffer_and_quit
    cmp                 al, LINE_BREAK
    je                  .copy_rules_from_string_buffer  ; line break found

    add                 r14, r15                        ; Update the string buffer offset.

    cmp                 r15, rdx
    jb                  .free_string_buffer_and_quit    ; The input ended before the first line break.

    ; Reallocate the string buffer.
    REALLOC             rbp, r12, .free_string_buffer_and_quit

    jmp                 .load_string_chunk

.copy_rules_from_string_buffer:
    add                 r14, rcx                        ; Update the string buffer offset.

    ; Calculate the rules buffer offset (bytes read - (line break position + 1)).
    ; Register r15 is now in a legal state.
    lea                 r15, [r15 - 1]
    sub                 r15, rcx                        

    MALLOC              .free_string_buffer_and_quit, 0 ; Allocate rules buffer.

    ; Check if there are any preloaded rules to copy.
    test                r15, r15
    jz                  .load_rules

    ; Copy the first batch of rules from the string buffer.
    mov                 rcx, r15                        ; length
    lea                 rsi, [rbp + r14 + 1]            ; start of preloaded rules in input buffer
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
    add                 r15, rax                        ; Move the offset.
    cmp                 rax, rdx
    jbe                 .build_rules_registry           ; all rules loaded

    REALLOC             rbx, r13, .free_both_buffers_and_quit
    jmp                 .load_rules_chunk

.build_rules_registry:
    xor                 rdx, rdx                        ; rules buffer offset
    lea                 r9, [rel rules_registry]
    mov                 r8, r15                         ; remaining rules buffer space

.register_rule:
    SCAN_LINE           rbx, rdx, r8, .free_both_buffers_and_quit
    cmp                 al, LINE_BREAK
    jne                 .free_both_buffers_and_quit     ; unterminated line or no rule
    mov                 al, [rbx + rdx]                 ; Extract rule character.

    ; Save rule info to the registry.
    lea                 r11, [rbx + rdx]
    mov                 rsi, rax                        ; rule character
    sub                 rsi, ASCII_START                ; registry character number
    add                 rsi, RULE_REGISTRY_ENTRY_SIZE   ; registry character offset
    mov                 [r9 + rsi], r11                 ; start pointer
    mov                 [r9 + rsi + 8], rcx             ; length

    inc                 rdx                             ; first character after the line break
    add                 rdx, rcx                        ; Advance the rules buffer offset.
    sub                 r8, rcx                         ; Update the available space size.
    add                 r9, RULE_REGISTRY_ENTRY_SIZE
    cmp                 rdx, r15
    jb                  .register_rule                  ; There are still rules to register.

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
