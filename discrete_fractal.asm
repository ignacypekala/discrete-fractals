global _start

SYS_EXIT                equ 60
SYS_READ                equ 0
SYS_WRITE               equ 1
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

FRAME_SIZE              equ 4096

INITIAL_BUFFER_SIZE     equ FRAME_SIZE

WRITE_BUFFER_SIZE       equ 64 * FRAME_SIZE

RULE_REGISTRY_ENTRY_SIZE        equ 8 * 2                  ; base pointer + rule length
RULE_REGISTRY_TOTAL_SIZE        equ (ASCII_END - ASCII_START + 1) * RULE_REGISTRY_ENTRY_SIZE

STACK_ENTRY_SIZE        equ 8 * 3                       ; base pointer + string length + current index

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

;
; Push one set of three values into the "stack" buffer, without checking if it will fit. 
; Reallocate the buffer if there is is no space of another set of three.
;
; Parameters:
;  %1 - base pointer
;  %2 - current offset
;  %3 - total buffer size
;  %4 - value 1
;  %5 - value 2
;  %6 - value 3
;  %7 - reallocation failure jump label
;
; Affected registers:
;  rcx, r11 - clobbered
;  %1  - updated on reallocation
;  %3  - increased on reallocation
;  %2  - moved up by STACK_ENTRY_SIZE
;
%macro PUSH 7
    lea                 rcx, [%1 + %2]
    mov                 qword [rcx], %4
    mov                 qword [rcx + 8], %5
    mov                 qword [rcx + 16], %6
    add                 %2, STACK_ENTRY_SIZE
    
    lea                 r11, [%3 - STACK_ENTRY_SIZE]
    sub                 r11, %2
    jns                 %%return                        ; (total size - offset) < STACK_ENTRY_SIZE
    REALLOC             %1, %3, %7
%%return:
%endmacro

%macro POP 1
    sub                 %1, STACK_ENTRY_SIZE 
%endmacro


;
; Flush the write buffer to std_out. Reattempt on partial writes.
;
; Parameters:
;  %1 - current write buffer offset
;  %2 - write error jump label
;
; Affected registers:
;  rcx, r11, rax, rdi - clobbered
;  rsi - pointer to the character following the last read (write_buffer + WRITE_BUFFER_SIZE on success)
;  %1 - number of bytes left to read
;  
%macro FLUSH 2
%%flush_write_buffer:
    mov                 eax, SYS_WRITE
    mov                 edi, STD_OUT
    lea                 rsi, [rel write_buffer]
    mov                 rdx, %1
    syscall
    test                rax, rax
    jb                  %2
    cmp                 rax, %1
    jz                  %%return                        ; buffer flushed completely
    add                 rsi, rax 
    sub                 %1, rax
    jmp %%flush_write_buffer                            ; reattempt flush
%%return:
    sub                 %1, rax
%endmacro


section .bss

input_buffer:           resq 1
input_buffer_size:      resq 1
input_buffer_offset:    resq 1

first_line_length:      resq 1

rules_registry:         resb RULE_REGISTRY_TOTAL_SIZE

alignb                  FRAME_SIZE
write_buffer:           resb WRITE_BUFFER_SIZE
write_buffer_offset     resq 1

section .text

;
; Registers:
;  rax, rdi, rsi, rdx, r10, r8, r9 - syscall parameters or localized scratchpads
;  rcx, r11 - localized scratchpads often clobbered by syscalls
;  rbp, rbx - buffer pointers
;  r12, r13, r14 - buffer states
;  r15 - scratchpad
;

_start:
    ; Validate parameter count.
    pop                 rax
    cmp                 rax, PARAMETER_COUNT
    jnz                 .error_exit
    pop                 rax                             ; program name

    ; Allocate input buffer.
    ; TODO: Manage the address hints
    MALLOC              .error_exit, 0

    ; Initialize the input buffer state.
    mov                 rbp, rax                        ; base address
    mov                 r12, rsi                        ; total size
    xor                 r14, r14                        ; current offset

.load_input:
    READ                rbp, r14, r12, .free_input_buffer_and_quit 
    add                 r14, rax                        ; advance offset
    cmp                 rax, r12
    jb                  .scan_input                     ; eof
    REALLOC             rbp, r12, .free_input_buffer_and_quit 
    jmp                 .load_input

.scan_input:
    xor                 rdx, rdx                        ; scan iterator
    mov                 r8, r14

.scan_first_line:
    SCAN_LINE           rbp, rdx, r8, .free_input_buffer_and_quit 
    add                 rdx, rcx                        ; advance offset
    sub                 r8, rcx                         ; update scan limit
    cmp                 al, LINE_BREAK
    jne                 .scan_first_line                ; line break not found

    inc                 rdx                             ; skip line break
    dec                 r8

    lea                 rcx, [rdx - 1]
    mov                 [rel first_line_length], rcx

.build_rules_registry:
    lea                 rbx, [rel rules_registry]

.register_rule:
    SCAN_LINE           rbp, rdx, r8, .free_input_buffer_and_quit
    cmp                 al, LINE_BREAK
    jne                 .free_input_buffer_and_quit     ; unterminated line or no rule

    ; Save rule info to the registry.
    lea                 r11, [rbp + rdx]                ; rule input buffer pointer
    mov                 al, [r11]                       ; rule character

    test                rcx, rcx
    jz                  .continue_registration          ; the rule is empty
    inc                 r11
    dec                 rcx                             ; skip the rule character

    mov                 rsi, rax                        
    sub                 rsi, ASCII_START                ; registry character index
    shl                 rsi, 4                          ; registry character offset
    mov                 [rbx + rsi], r11                ; start pointer
    mov                 [rbx + rsi + 8], rcx            ; length
    
    inc                 rcx                             ; revert the rule character exclusion

.continue_registration:
    inc                 rcx                             ; first character after the line break
    add                 rdx, rcx                        ; Advance the rules buffer offset.
    sub                 r8, rcx                         ; Update the available space size.
    cmp                 rdx, r14
    jb                  .register_rule                  ; There are still rules to register.

    ; Save input buffer state
    mov                 [rel input_buffer], rbp
    mov                 [rel input_buffer_size], r12    ; not needed until cleanup
    mov                 [rel input_buffer_offset], r14

    ; Parse the iteration count
    pop                 r8                              ; iteration count string pointer
    xor                 eax, eax
    xor                 r15, r15                        ; final n
    
.parse_iteration_count_digit:
    mov                 al, [r8]                        ; parsed character
    test                al, al
    jz                  .prepare_for_main_processing    ; string parsed
    cmp                 al, '9'
    ja                  .free_input_buffer_and_quit     ; invalid character
    sub                 al, '0'
    jb                  .free_input_buffer_and_quit     ; invalid character
    
    ; The maximum intermediate result (2^32 - 1) easily fits within the 
    ; 64-bit register, guaranteeing imul will never truncate the value. 
    ; Additionally, because the sign bit always remains 0, imul safely 
    ; treats it as a positive integer, perfectly mirroring unsigned math.
    imul                r15, 10
    add                 r15, rax
    
    inc                 r8
    jmp                 .parse_iteration_count_digit

    xor                 r9, r9                          ; write buffer offset

.prepare_for_main_processing:
    ; Allocate the "stack" on the heap. Discard the system stack in favor of the heap one.
    MALLOC              .free_input_buffer_and_quit, 0  
    mov                 rsp, rax                        ; base pointer
    mov                 r12, rsi                        ; total size
    xor                 r13, r13                        ; current offset

    ; Push the initial execution on the input string.
    mov                 r9, [rel first_line_length]
    test                r9, r9
    jz                  .write_remaining_output
    PUSH                rsp, r13, r12, rbp, 0, r9, .free_stack_and_input_from_memory

    xor                 r14, r14                        ; character store

.process_character:
    lea                 rbp, [rsp + r13 - STACK_ENTRY_SIZE]     ; stack top pointer
    mov                 rcx, [rbp + 8]                          ; character index
    inc                 qword [rbp + 8]                         ; mark character as handled

    mov                 r11, [rbp]                      ; base pointer
    mov                 r14b, [r11 + rcx]               ; string character
    ; TODO: change rax to r14b everywhere

    ; Identify the rule
    mov                 rcx, r14
    sub                 rcx, ASCII_START                ; character index
    shl                 rcx, 4                          ; character offset
    mov                 rdi, [rbx + rcx]                ; rule pointer

    ; Check if rule application should be skipped.
    test                rdi, rdi
    jz                  .write_char                     ; there is no rule
    test                r15, r15
    jz                  .write_char                     ; recursion depth limit reached

    ; Grab rule details
    mov                 rdx, [rbx + rcx + 8]            ; rule length
    test                rdx, rdx
    jz                  .continue_recursion             ; the rule is empty

    ; Push an execution on this rule.
    PUSH                rsp, r13, r12, rdi, 0, rdx, .free_stack_and_input_from_memory
    dec                 r15                             ; recursion depth counter
    jmp                 .process_character

.write_char:
    cmp                 r9, WRITE_BUFFER_SIZE
    jb                  .append_character              ; sufficient space
    FLUSH               r9, .free_stack_and_input_from_memory    
   
.append_character:
    lea                 r11, [rel write_buffer]
    mov                 [r11 + r9], r14b
    inc                 r9

.continue_recursion:
    mov                 rcx, [rbp + 8]                  ; character index
    cmp                 rcx, [rbp + 16]                 ; string length
    jb                  .process_character              ; the top recursive call is not completed

    POP                 r13
    inc                 r15                             ; recursion depth counter
    sub                 rbp, STACK_ENTRY_SIZE           ; correct stack top pointer
    test                r13, r13
    jnz                 .continue_recursion

.write_remaining_output:
    test                r9, r9
    jz                  .end
    FLUSH               r9, .free_stack_and_input_from_memory

.end:
    mov                 eax, SYS_EXIT
    xor                 edi, edi
    syscall

.free_stack_and_input_from_memory:
    ; TODO: Free the input buffer from memory and free the stack from register.

.free_both_buffers_and_quit:
    ; TODO: Free the "stack" buffer.
    nop

.free_input_buffer_and_quit:
    ; TODO: Free the input buffer.
    nop

.error_exit:
    mov                 eax, SYS_EXIT
    mov                 edi, ERROR_CODE
    syscall
