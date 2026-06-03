;
;                                        Discrete Fractals
;                                         by Ignacy Pękała
;
; Generates an ASCII-based discrete fractal by applying string replacement rules. The program reads
; an initial string of symbols (ASCII 33-126) and a sequence of replacement rules from standard
; input. It performs exactly n iterations of substitution, where every matching symbol in the
; current string is replaced by its specified replacement sequence. After computing the final
; fractal sequence, the program prints the resulting string to standard output, terminated by a
; newline.
;
; Usage:
; ./discrete_fractal n
; 
; Input (via stdin):
;   [initial string]
;   [rule 1]
;   [rule 2]
;   ...
;

global _start

SYS_EXIT                equ 60
SYS_READ                equ 0
SYS_WRITE               equ 1
SYS_BRK                 equ 12
SYS_MMAP                equ 9
SYS_MUNMAP              equ 11
SYS_MREMAP              equ 25

PROT_READ               equ 0x1
PROT_WRITE              equ 0x2
MAP_PRIVATE             equ 0x02
MAP_ANONYMOUS           equ 0x20
MREMAP_MAYMOVE          equ 0x1

MAX_ITERATIONS          equ 0xffffffff                  ; 2^32 - 1

STD_IN                  equ 0
STD_OUT                 equ 1

LINE_BREAK              equ 10
MIN_SYMBOL_ASCII        equ 33
MAX_SYMBOL_ASCII        equ 126
OUTPUT_CHUNK_SIZE       equ 64 * 1024

PAGE_SIZE               equ 4096
BASE_ALLOC_SIZE         equ PAGE_SIZE

REGISTRY_ENTRY_SIZE     equ 8 * 2                       ; base pointer + rule length
REGISTRY_TOTAL_SIZE     equ (MAX_SYMBOL_ASCII - MIN_SYMBOL_ASCII + 1) * REGISTRY_ENTRY_SIZE

STACK_ENTRY_SIZE        equ 8 * 3                       ; base pointer + string length + current index

EXPECTED_ARGC           equ 2                           ; program name + iteration count
EXIT_FAILURE            equ 1

;
; Allocate BASE_ALLOC_SIZE bytes of anonymous memory via sys_mmap. Jump to %1 on failure.
;
; Parameters:
;   %1 - error jump label                               (label)
;
; Affected registers:
;   rax - pointer to the allocated block (or negative error code after jump)
;   rdi - 0
;   rsi - buffer size
;   rdx - protection flags
;   r10 - map flags
;   r8  - -1
;   r9  - 0
;   rcx, r11 - clobbered by syscall
;
%macro MALLOC 1
    mov                 rax, SYS_MMAP
    xor                 rdi, rdi                        ; zero address hint to let os choose
    mov                 rsi, BASE_ALLOC_SIZE
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
;   %1 - original address                               (r/m64)
;   %2 - original size                                  (r/m64)
;   %3 - error jump label                               (label)
;
; Affected registers:
;   rax - pointer to the reallocated block (or negative error code after jump)
;   rdi - original address
;   rsi - original size
;   rdx - new size (%2 * 2)
;   r10 - mremap flags
;   rcx, r11 - clobbered by syscall
;
%macro REALLOC 3
    mov                 rax, SYS_MREMAP
    mov                 rdi, %1                         ; original address
    mov                 rsi, %2                         ; original size
    mov                 rdx, rsi
    shl                 rdx, 1                          ; double buffer size
    mov                 r10, MREMAP_MAYMOVE
    syscall
    test                rax, rax
    js                  %3
    mov                 %1, rax                         ; update address
    mov                 %2, rdx                         ; update size
%endmacro

;
; Scan a buffer for the first occurrence of a line break, ensuring all characters 
; are within an allowed range during the process. Jump to a designated label if 
; an invalid character is encountered.
;
; Parameters:
;   %1 - base address                                   (r64)
;   %2 - offset                                         (r64)
;   %3 - read length limit                              (r64/imm)
;   %4 - invalid character jump label                   (label)
;
; Affected registers (on normal return):
;   rax - al contains the line break character, or 0 if the read limit was reached
;   rcx - number of bytes scanned (index of the line break, or exactly %3 if limit reached)
;   r11 - max read pointer (%1 + %2 + %3)
;
; Affected registers (on jump to %4):
;   rax - al contains the invalid character that triggered the jump
;   rcx - absolute memory pointer to the invalid character
;
%macro SCAN_LINE 4
    lea                 rcx, [%1 + %2]                  ; start pointer
    lea                 r11, [rcx + %3]                 ; end pointer
    xor                 eax, eax                        ; clear register for scanned byte

%%scan_character:
    cmp                 rcx, r11
    jz                  %%return                        ; read limit reached

    mov                 al, [rcx]                       ; current byte
    cmp                 al, LINE_BREAK
    je                  %%return                        ; line break found
    cmp                 al, MIN_SYMBOL_ASCII
    jb                  %4                              ; below allowed ascii range
    cmp                 al, MAX_SYMBOL_ASCII
    ja                  %4                              ; above allowed ascii range

    inc                 rcx
    jmp                 %%scan_character

%%return:
    ; calculate position relative to start offset
    sub                 rcx, %1
    sub                 rcx, %2
%endmacro

;
; Push one set of three values into the "stack" buffer, without checking if it will fit. 
; Reallocate the buffer if there is no space for another set of three.
;
; Parameters:
;   %1 - base pointer                                   (r64)
;   %2 - current offset                                 (r64)
;   %3 - total buffer size                              (r64)
;   %4 - value 1                                        (r64/imm)
;   %5 - value 2                                        (r64/imm)
;   %6 - value 3                                        (r64/imm)
;   %7 - reallocation failure jump label                (label)
;
; Affected registers:
;   rcx, r11 - clobbered
;   %1  - updated on reallocation
;   %3  - increased on reallocation
;   %2  - moved up by STACK_ENTRY_SIZE
;
%macro PUSH 7
    lea                 rcx, [%1 + %2]
    mov                 qword [rcx], %4
    mov                 qword [rcx + 8], %5
    mov                 qword [rcx + 16], %6
    add                 %2, STACK_ENTRY_SIZE
    
    lea                 r11, [%3 - STACK_ENTRY_SIZE]
    sub                 r11, %2
    jns                 %%return                        ; space remains for next push
    REALLOC             %1, %3, %7
%%return:
%endmacro

;
; Decrement the stack offset. Mostly a visual counterpart to PUSH.
;
; Parameters:
;   %1 - current offset                                 (r/m64)
; 
; Affected registers:
;   %1 - decreased by STACK_ENTRY_SIZE
;
%macro POP 1
    sub                 %1, STACK_ENTRY_SIZE 
%endmacro


;
; Flush the write buffer to std_out. Reattempt on partial writes.
;
; Parameters:
;   %1 - current write buffer offset                    (r/m64)
;   %2 - write error jump label                         (label)
;
; Affected registers:
;   rcx, r11, rax, rdi - clobbered
;   rsi - pointer to the character following the last read (stdout_flush_buffer + OUTPUT_CHUNK_SIZE on success)
;   %1 - number of bytes left to read
;  
%macro FLUSH 2
%%flush_stdout_flush_buffer:
    mov                 eax, SYS_WRITE
    mov                 edi, STD_OUT
    lea                 rsi, [rel stdout_flush_buffer]
    mov                 rdx, %1
    syscall
    test                rax, rax
    js                  %2
    cmp                 rax, %1
    jz                  %%return                        ; entire buffer flushed
    add                 rsi, rax 
    sub                 %1, rax
    jmp                 %%flush_stdout_flush_buffer     ; retry partial flush
%%return:
    sub                 %1, rax
%endmacro


;
; Append a single character to the write buffer. If the buffer has reached its capacity, 
; flush its contents to stdout before appending. Jump to a designated label on 
; flush failures.
;
; Parameters:
;   %1 - write buffer offset                            (r64)
;   %2 - character to write                             (r8/imm8)
;   %3 - flush error jump label                         (label)
;
; Affected registers:
;   r11 - clobbered (used to load the write buffer base pointer)
;   %1  - incremented by 1 (or reset to 1 if a buffer flush is triggered)
;   rax, rcx, rdx, rdi, rsi - conditionally clobbered if FLUSH is invoked
;
%macro WRITE 3
    cmp                 %1, OUTPUT_CHUNK_SIZE
    jb                  %%append_character              ; capacity available
    FLUSH               %1, %3
%%append_character:
    lea                 r11, [rel stdout_flush_buffer]
    mov                 [r11 + %1], byte %2
    inc                 %1
%endmacro

;
; Free a block of memory allocated with sys_mmap, without error handling.
; Error handling is ommitted because this macro is only used at the end of execution, either upon
; error or right before a successful execution.
;
; Parameters:
;   %1 - base address                                   (r/m64)
;   %2 - block size                                     (r/m64)
;
; Affected registers:
;   rax - sys_munmap return value
;   rdi - %1
;   rsi - %2
;   rcx, r11 - clobbered by syscall
;
%macro FREE 2
    mov                 rax, SYS_MUNMAP
    mov                 rdi, %1
    mov                 rsi, %2
    syscall
%endmacro

section .bss

input_buffer_pointer:   resq 1
input_buffer_capacity:  resq 1
initial_string_length:  resq 1
rules_registry:         resb REGISTRY_TOTAL_SIZE

alignb                  PAGE_SIZE
stdout_flush_buffer:           resb OUTPUT_CHUNK_SIZE

section .text

;
; Program Entry Point.
; Manages the execution of the fractal generator. It uses dynamic memory mapping 
; (sys_mmap/sys_mremap) to handle resizable I/O buffers and a custom heap-allocated 
; stack, which prevents standard stack overflows during deep recursion. Replacement 
; rules are parsed into a direct-mapped ASCII array for O(1) lookups. The main loop 
; evaluates and recursively expands characters up to the target iteration depth, 
; buffering the output and flushing it to standard output in chunks to minimize 
; syscall overhead.
;
; Global Register Usage:
;   rax, rdi, rsi, rdx, r10, r8, r9 - syscall parameters or short-lived scratchpads
;   rcx, r11 - short-lived scratchpads often clobbered by syscalls
;   rbp, rbx - structural base pointers
;   r12, r13, r14, r15 - long-lived state variables
;

_start:
    ; Validate parameter count passed by os.
    pop                 rax
    cmp                 rax, EXPECTED_ARGC
    jnz                 .error_exit
    pop                 rax                             ; skip program name

    ; initial setup of input buffer
    MALLOC              .error_exit
    mov                 rbp, rax                        ; base address
    mov                 r12, rsi                        ; total capacity
    xor                 r14, r14                        ; write offset

; 
; Read standard input into the dynamically resizing input buffer.
; Repetitively populates the buffer with bytes from standard input. 
; On partial reads, retries with the remaining bytes. 
; On io error, frees the input buffer and exits. 
; On eof, proceeds to input parsing.
;
; Active Registers:
;   rbp - input buffer base address
;   r12 - input buffer total capacity
;   r14 - current write offset within the buffer
;
.read_stdin_loop:
    mov                 rax, SYS_READ
    xor                 edi, edi                        ; standard input fd
    lea                 rsi, [rbp + r14]                ; write target address
    mov                 rdx, r12
    sub                 rdx, r14                        ; maximum bytes to read
    syscall
    test                rax, rax
    js                  .free_input_buffer_and_quit     ; read failure
    jz                  .parse_initial_string           ; end of file reached
    add                 r14, rax                        ; advance offset by read length
    cmp                 rax, rdx
    jb                  .read_stdin_loop                ; retry if buffer not fully populated
    REALLOC             rbp, r12, .free_input_buffer_and_quit 
    jmp                 .read_stdin_loop                ; continue reading into expanded buffer

;
; Scan the populated input buffer to locate the first line break.
; Extracts the initial string length and adjusts pointers to begin parsing 
; subsequent lines as replacement rules.
;
; Active Registers:
;   rbp - input buffer base address
;   r14 - total bytes read from standard input
;
.parse_initial_string:
    mov                 r8, r14                         ; scan boundary limit
    xor                 rdx, rdx                        ; initial scan offset
    SCAN_LINE           rbp, rdx, r8, .free_input_buffer_and_quit 
    cmp                 al, LINE_BREAK
    jne                 .free_input_buffer_and_quit     ; strict termination required
    mov                 [rel initial_string_length], rcx
    inc                 rcx                             ; bypass line break character
    add                 rdx, rcx                        ; advance parsing offset
    sub                 r8, rcx                         ; reduce remaining bytes limit

;
; Populate the direct-mapped rule registry array from standard input.
; Iterates through remaining lines, using the first character of each line 
; as the rule trigger and the remainder as the replacement string.
;
; Active Registers:
;   rbp - input buffer base address
;   rbx - rules registry base pointer
;   r14 - total bytes read from standard input
;   rdx - current read offset within input buffer
;   r8  - remaining bytes left to process
;
.initialize_rules_registry:
    lea                 rbx, [rel rules_registry]
    cmp                 rdx, r14
    jae                 .finalize_input_parsing         ; bypass if no rules exist

.parse_rule_line:
    SCAN_LINE           rbp, rdx, r8, .free_input_buffer_and_quit
    cmp                 al, LINE_BREAK
    jne                 .free_input_buffer_and_quit     ; malformed or missing rule line
    test                rcx, rcx
    jz                  .free_input_buffer_and_quit     ; empty rule line detected

    ; Extract target character and validate rule body.
    lea                 r11, [rbp + rdx]                ; pointer to rule definition
    mov                 al, [r11]                       ; character to be replaced

    test                rcx, rcx
    jz                  .free_input_buffer_and_quit     ; rule body missing
    inc                 r11                             ; pointer to replacement string
    dec                 rcx                             ; string length excluding trigger char

    ; Compute registry offset mapped to ascii value.
    mov                 rsi, rax                        
    sub                 rsi, MIN_SYMBOL_ASCII           ; normalized registry index
    shl                 rsi, 4                          ; scale by registry entry size (16 bytes)

    ; Ensure rule uniqueness.
    mov                 rax, [rbx + rsi]
    test                rax, rax
    jnz                 .free_input_buffer_and_quit     ; multiple rules for same character
    
    ; Populate registry entry.
    mov                 [rbx + rsi], r11                ; replacement string pointer
    mov                 [rbx + rsi + 8], rcx            ; replacement string length
    
    inc                 rcx                             ; restore length for offset math

.resume_rule_parsing:
    inc                 rcx                             ; jump over line break character
    add                 rdx, rcx                        ; advance parsing offset
    sub                 r8, rcx                         ; reduce remaining bytes limit
    cmp                 rdx, r14
    jb                  .parse_rule_line                ; parse next line if data remains

;
; Persist standard input configuration and parse the command-line argument 
; specifying maximum recursion depth into an integer.
;
; Active Registers:
;   rbp - input buffer base address
;   r12 - input buffer total capacity
;
.finalize_input_parsing:
    ; Offload input state to memory, freeing registers for core logic.
    mov                 [rel input_buffer_pointer], rbp
    mov                 [rel input_buffer_capacity], r12
    
    ; Extract recursion depth argument.
    pop                 r8                              ; iteration count arg pointer
    mov                 al, byte [r8]
    test                al, al                        
    jz                  .free_input_buffer_and_quit     ; arg missing

    xor                 eax, eax
    xor                 r15, r15                        ; final n accumulator
    xor                 r10, r10
    
.parse_iteration_count:
    mov                 al, [r8]                        ; current digit character
    test                al, al
    jz                  .init_recursive_stack           ; null terminator reached
    cmp                 al, '9'
    ja                  .free_input_buffer_and_quit     ; outside numeric ascii range
    sub                 al, '0'
    jb                  .free_input_buffer_and_quit     ; outside numeric ascii range
    
    ; The maximum intermediate result (2^32 - 1) easily fits within the 
    ; 64-bit register, guaranteeing imul will never truncate the value. 
    ; Additionally, because the sign bit always remains 0, imul safely 
    ; treats it as a positive integer, perfectly mirroring unsigned math.
    imul                r15, 10
    add                 r15, rax
    
    ; Moving a 32-bit immediate into a 32-bit register zero-extends 
    ; it to 64 bits, allowing a valid 64-bit comparison against r15.
    mov                 r10d, MAX_ITERATIONS
    cmp                 r15, r10
    ja                  .free_input_buffer_and_quit     ; exceeds maximum supported depth

    inc                 r8
    jmp                 .parse_iteration_count

;
; Initialize the heap-based stack designed to track recursive string processing 
; and push the initial string base evaluation frame.
;
; Active Registers:
;   r15 - maximum recursion depth
;   rbx - rules registry pointer
;
.init_recursive_stack:
    mov                 r14, rbp                        ; preserve input buffer base
    
    MALLOC              .free_input_buffer_and_quit
    mov                 rbp, rax                        ; stack base address
    mov                 r12, rsi                        ; stack total capacity
    xor                 r13, r13                        ; stack current offset

    ; Bootstrap recursive evaluation.
    mov                 r9, [rel initial_string_length]
    test                r9, r9
    jz                  .write_remaining_output         ; abort if initial string empty
    PUSH                rbp, r13, r12, r14, 0, r9, .free_both_buffers_and_quit

    xor                 r14, r14                        ; character evaluation scratchpad
    xor                 r9, r9                          ; stdout write buffer offset

;
; Core processing loop. Pops the current character from the active stack frame 
; and determines whether to recursively expand it based on the rule registry 
; or write it directly to the output buffer.
;
; Active Registers:
;   rbp - stack base address
;   r12 - stack total capacity
;   r13 - stack current offset
;   r15 - current recursion depth limit
;   r9  - stdout write buffer offset
;   rbx - rules registry base pointer
;
.evaluate_character:
    lea                 r11, [rbp + r13 - STACK_ENTRY_SIZE]     ; active frame pointer
    mov                 rcx, [r11 + 8]                          ; current character index
    inc                 qword [r11 + 8]                         ; increment index for next cycle

    mov                 r11, qword [r11]                ; string base pointer
    mov                 r14b, [r11 + rcx]               ; extract character to evaluate

    ; Calculate registry offset for target character.
    mov                 rcx, r14
    sub                 rcx, MIN_SYMBOL_ASCII           ; normalized registry index
    shl                 rcx, 4                          ; scale by registry entry size
    mov                 rdi, [rbx + rcx]                ; replacement rule pointer

    ; Determine recursive viability.
    test                rdi, rdi
    jz                  .write_character                ; no replacement rule mapped
    test                r15, r15
    jz                  .write_character                ; recursion depth exhausted

    mov                 rdx, [rbx + rcx + 8]            ; replacement string length
    test                rdx, rdx
    jz                  .resume_parent_frame            ; rule replaces char with empty string

    ; Deploy child evaluation frame.
    PUSH                rbp, r13, r12, rdi, 0, rdx, .free_both_buffers_and_quit
    dec                 r15                             ; deduct recursion depth allowance
    jmp                 .evaluate_character

.write_character:
    WRITE               r9, r14b, .free_both_buffers_and_quit

;
; Evaluate the status of the active stack frame. If the frame is incomplete, 
; jumps back to evaluate the next character. Otherwise, pops the frame and 
; restores the parent recursion state.
;
.resume_parent_frame:
    lea                 r11, [rbp + r13 - STACK_ENTRY_SIZE]     ; active frame pointer
    mov                 rcx, [r11 + 8]                          ; current character index
    cmp                 rcx, [r11 + 16]                         ; compare against string length
    jb                  .evaluate_character                     ; frame execution incomplete

    POP                 r13
    inc                 r15                             ; refund recursion depth allowance
    test                r13, r13
    jnz                 .resume_parent_frame            ; continue if parent frames remain

.write_remaining_output:
    WRITE               r9, LINE_BREAK, .free_both_buffers_and_quit
    FLUSH               r9, .free_both_buffers_and_quit

    FREE                rbp, r12
    mov                 rbp, [rel input_buffer_pointer]
    mov                 r12, [rel input_buffer_capacity]
    FREE                rbp, r12

    mov                 eax, SYS_EXIT
    xor                 edi, edi
    syscall

.free_both_buffers_and_quit:
    FREE                rbp, r12
    mov                 rbp, [rel input_buffer_pointer]
    mov                 r12, [rel input_buffer_capacity]

.free_input_buffer_and_quit:
    FREE                rbp, r12

.error_exit:
    mov                 eax, SYS_EXIT
    mov                 edi, EXIT_FAILURE
    syscall
