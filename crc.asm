section .bss
    buffer: resb 0x10008               ; buffer for reading/printing
                                       ;    the size of the buffer is 4 KiB
                                       ;    since it allows any data fragment
                                       ; to be read with a single function call
    lookup_table: resq 256             ; holds every  byte's CRC remainder

section .text
    global _start

file_error:                            ; report an error that occurred while
                                       ;  the file was open
    mov rdi, r14                       ; load file descriptor into rdi
    mov eax, 3
    syscall                            ; call sys_close
    mov eax, 60
    mov edi, 1
    syscall                            ; call sys_exit with code 1


read_n_bytes:
    push rsi
    push rbx
    push rdx
    mov r10, rdi                       ; r10 holds total number bytes 
                                       ;    to be read and doesn't change 
                                       ;    until end of function
    mov edx, edi                       ; rdx holds number of bytes left to be read
    mov rdi, r14                       ; rdi holds file descriptor and
                                       ;   doesn't change until end of function
    mov rsi, buffer                    ; rsi holds pointer to 
                                       ;    the desired location in buffer
    xor ebx, ebx                       ; rbx holds number of bytes already read

.loop_read:
    xor eax, eax                       ; prepare rax for sys_read
    syscall                            ; call sys_read
    cmp rax, 0
    jle .read_error                    ; error: sys_read failure
    add rsi, rax                       ; move buffer pointer by 
                                       ;    number of bytes read
    sub rdx, rax                       ; decrease number of bytes 
                                       ;    left to be read
    add rbx, rax                       ; increase number of bytes already read
    cmp rbx, r10
    jnz .loop_read                     ; if desired number of bytes 
                                       ;   was read, end loop
    pop rdx
    pop rbx
    pop rsi
    ret

.read_error:
    call file_error



_start:
    cmp qword [rsp], 3
    jnz .exit_error                    ; error: invalid number of arguments
    mov r14, [rsp + 16]                ; r14 temporarily holds file path
    mov rdi, [rsp + 24]                ; rdi temporarily holds 
                                       ;    the CRC polynomial string
.convert_poly:                         ; convert polynomial to numeric value
    xor eax, eax                       ; rax holds the numeric value of 
                                       ;    the CRC polynomial
    xor ecx, ecx                       ; rcx holds counter, which is also 
                                       ;   the buffer pointer offset

.loop_convert_poly:
    mov dl, byte [rdi + rcx]           ; load wanted byte from buffer to dl
    test dl, dl
    jz .finish_conversion              ; end conversion on \0 character
    sub dl, 48                         ; convert ascii code of byte to integer
    js .exit_error                     ; error: character was less than '0'
    cmp dl, byte 2
    jge .exit_error                    ; error: character was greater than '1'
    shl rax, 1                         ; shift the result register
    add al, dl                         ; add the converted numeric value 
                                       ;    of the character
    inc ecx                            ; increment counter
    jmp .loop_convert_poly

.finish_conversion:
    cmp rcx, 0
    jle .exit_error                    ; error: polynomial string was empty
    cmp rcx, 65
    jge .exit_error                    ; error: CRC polynomial has degree > 64
    mov r12, rcx                       ; r12 - degree of crc polynomial
    mov r13, rax                       ; r13 - numeric value of CRC polynomial
    mov rcx, r12
    ror r13, cl                        ; rotate r13 so the polynomial is in the
                                       ;  most significant bits

.fill_lookup_table:
    xor ecx, ecx
    mov cl, 255                        ; rcx iterates through all bytes

.loop_fill_table:
    mov ebx, ecx                       ; ebx stores the currently processed 
                                       ;  byte value (before rotation)
    ror rcx, 8                         ; rotate the byte so it is in the 
                                       ;  most significant 8 bits
    mov edx, 8                         ; edx iterates through all the bits of
                                       ;  the currently computed byte


.loop_byte_remainder:
    shl rcx, 1                         ; shift byte left by 1
    jnc .next_iteration                ; if msb was 0, do nothing
    xor rcx, r13                       ; if msb was 1, xor its right-hand side
                                       ;  into its remainder

.next_iteration:
    dec edx                            ; decrement bit counter
    test edx, edx
    jnz .loop_byte_remainder           ; if there are bits left, repeat
    lea eax, [rel lookup_table]
    mov qword [eax + ebx * 8], rcx     ; all bits of the byte handled, 
                                       ;    update remainder in lookup table
    mov ecx, ebx                       ; whole byte handled, 
                                       ;    restore nonshifted byte value
    dec ebx                            ; decrement byte counter
    loop .loop_fill_table              ; if byte is nonzero, 
                                       ;    repeat outer loop step

.open_file:
    mov rdi, r14                       ; rdi - file path
    mov esi, 4                         ; rsi - user only has read permission
    xor edx, edx                       ; rdx - read-only flag
    mov eax, 2
    syscall                            ; call sys_open
    js .exit_error                     ; error - file couldn't be opened

    mov r14, rax                       ; r14 - file descriptor
    xor eax, eax
    xor edx, edx                       ; edx - CRC remainder

.file_loop:                            ; loops through the file
                                       ;    until the end condition is met
    mov rsi, rax                       ; rsi - current file offset, initially 0
    mov edi, 2
    call read_n_bytes                  ; read the 2-byte fragment data length
    xor ebx, ebx
    mov bx, word [rel buffer]          ; rbx - fragment data length
    lea edi, [ebx + 4]
    call read_n_bytes                  ; read fragment data + 4 offset bytes
    xor ecx, ecx                       ; ecx - buffer iterator
    xor eax, eax                       ; rax - working register
    test ebx, ebx
    jz .reposition                     ; if fragment has data length 0,
                                       ;    skip reading

.loop_bytes:
    mov rax, rdx
    shr rax, 56                        ; access the most significant byte
                                       ;    of the CRC remainder
    lea edi, [rel buffer]
    xor al, byte [edi + ecx]           ; xor the currently processed byte
                                       ;    into the working register
    lea edi, [rel lookup_table]
    mov rax, qword [edi + eax * 8]     ; read the remainder of the
                                       ;    currently processed byte
    shl rdx, 8                         ; shift remainder by 1 byte length
    xor rdx, rax                       ; xor control byte into the remainder
    inc ecx                            ; increment byte counter
    cmp ecx, ebx
    jnz .loop_bytes                    ; if there are bytes left,
                                       ;    process next byte
    
.reposition:                           ; prepare offset for next fragment
    lea edi, [rel buffer]
    movsxd rax, dword [edi + ecx]      ; rax - 64-bit relative offset change
    push rsi
    push rdx
    mov rdi, r14                       ; rdi - file descriptor
    mov rsi, rax                       ; rsi - offset change
    mov edx, 1                         ; edx - mark of offset relativity
    mov eax, 8
    syscall                            ; call sys_lseek
    test eax, eax
    js .file_error                     ; error: lseek failure
    pop rdx
    pop rsi
    cmp rax, rsi ; cmp rax, r8
    jnz .file_loop                     ; if new offset differs from previous,
                                       ;    read new fragment

.closing:                              ; all fragments processed, close file
    mov rdi, r14                       ; rdi - file descriptor
    mov eax, 3
    syscall                            ; sys_close
    test rax, rax
    js .exit_error                     ; error - close failure

.convert_output:                       ; convert CRC remainder to string
    xor ecx, ecx                       ; ecx - buffer iterator

.loop_output:
    lea edi, [rel buffer]
    mov byte [edi + ecx], 0            ; prepare buffer location for character
    shl rdx, 1                         ; shift CRC remainder by 1
    adc byte [edi + ecx], 48           ; convert number to its ascii value
    inc ecx
    cmp rcx, r12
    jnz .loop_output                   ; if there are remainder bits left,
                                       ;    repeat loop step
    mov byte [edi + ecx], 10           ; append newline character to output

.print_output:                         ; print output string to stdout
    inc r12                            ; r12 = degree + 1, print remainder + \n
    xor ebx, ebx                       ; ebx - number of bytes printed
    mov edi, 1                         ; edi - standard output marker
    lea rsi, [rel buffer]

.loop_print:
    mov rdx, r12
    sub edx, ebx                       ; rdx - number of bytes
                                       ;    left to be read
    mov eax, 1
    syscall                            ; call sys_write
    cmp rax, 0
    jle .exit_error                    ; error: write failure
    add ebx, eax                       ; update printed bytes counter
    add rsi, rax                       ; move buffer pointer
    cmp rbx, r12
    jnz .loop_print                    ; if there are bytes left,
                                       ;    repeat loop step
    
.finish:                               ; finish program - correct execution
    xor edi, edi
    mov eax, 60
    syscall                            ; call sys_exit with code 0

.file_error:                           ; report error while the file was open
    call file_error

.exit_error:                           ; report error while the file was closed
    mov edi, 1
    mov eax, 60
    syscall                            ; call sys_exit with code 1