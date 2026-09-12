; ============================================================
;  BOOTX64.ASM — UEFI mini-OS for x86_64 (pure NASM)
;  Features:
;    - autostart all *.obj from USB root
;    - menu of *.bin, select, run, return
;  Build:
;    nasm -f win64 bootx64.asm -o bootx64.obj
;    x86_64-w64-mingw32-ld -nostdlib \
;        -Wl,-entry,efi_main \
;        -Wl,-subsystem,10 \
;        -Wl,-file-alignment,0x200 \
;        -Wl,-section-alignment,0x1000 \
;        bootx64.obj -o BOOTX64.EFI
; ============================================================

        BITS 64
        DEFAULT REL

; ---------- EFI CONSTANTS ----------
%define EFI_SUCCESS             0
%define EFI_BUFFER_TOO_SMALL    5
%define EFI_FILE_MODE_READ      1
%define EfiLoaderData           1
%define ByProtocol              2
%define EFI_FILE_DIRECTORY      0x10

%define ST_ConIn                0x30
%define ST_ConOut               0x40
%define ST_BootServices         0x60

%define BS_AllocatePool         0x40
%define BS_FreePool             0x48
%define BS_HandleProtocol       0x98
%define BS_LocateHandle         0x68

%define ConOut_OutputString     0x08
%define ConOut_ClearScreen      0x30

%define ConIn_ReadKeyStroke     0x08

%define FS_OpenVolume           0x08

%define File_Open               0x08
%define File_Close              0x10
%define File_Read               0x20
%define File_GetInfo            0x40

; EFI_FILE_INFO offsets
%define FI_FileSize             0x08
%define FI_Attribute            0x48
%define FI_FileName             0x50

%define FILE_INFO_BUF_SIZE      1024
%define MAX_FS_HANDLES          64

; ---------- DATA ----------
section .data
align 8

EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID:
        dd 0x0964E5B2
        dw 0x6459
        dw 0x11D2
        db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

EFI_FILE_INFO_GUID:
        dd 0x09576E91
        dw 0x6D3F
        dw 0x11D2
        db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B

; ---------- UTF-16 STRINGS ----------
str_menu:       dw '-','-','-',' ','B','I','N',' ','m','e','n','u',' ','-','-','-', 13, 10, 0
str_prompt:     dw 's','e','l','e','c','t',' ','n','u','m','b','e','r',' ','(','0','=','e','x','i','t',')',':',' ', 0
str_err:        dw 'n','o',' ','p','r','o','g','r','a','m', 13, 10, 0
str_crlf:       dw 13, 10, 0
str_back:       dw 'r','e','t','u','r','n','e','d',' ','t','o',' ','O','S', 13, 10, 0
str_obj_run:    dw 'r','u','n','n','i','n','g',' ','O','B','J',':',' ', 0
str_bin_run:    dw 'r','u','n','n','i','n','g',' ','B','I','N',':',' ', 0
str_root:       dw '\', 0
str_dot_bin:    dw '.','B','I','N', 0
str_dot_obj:    dw '.','O','B','J', 0
str_space:      dw ' ', 0
str_hello:      dw 'U','E','F','I',' ','O','S',' ','L','o','a','d','e','r', 13, 10, 0

; ---------- BSS ----------
section .bss
align 8
SystemTable:    resq 1
BootServices:   resq 1
ConOut:         resq 1
ConIn:          resq 1
RootFS:         resq 1
FileHandle:     resq 1
FileInfoBuf:    resq 1
FileInfoSize:   resq 1
LoadFileInfoBuf:resq 1
UserChoice:     resq 1
LoadBuffer:     resq 1
LoadBufferSize: resq 1
FsHandles:      resq MAX_FS_HANDLES
FsHandleCount:  resq 1
FsProto:        resq 1
DirHandle:      resq 1
KeyBuffer:      resq 1
EchoBuf:        resq 2
NumBuf:         resq 8
NumUtf16:       resq 8

; ---------- TEXT ----------
section .text
global efi_main

; ------------------------------------------------------------------
; efi_main(EFI_HANDLE image_handle (rcx), EFI_SYSTEM_TABLE *st (rdx))
; ------------------------------------------------------------------
efi_main:
        ; Выравниваем стек: при входе RSP % 16 == 8 (после call).
        ; sub rsp, 8 делает RSP % 16 == 0.
        sub     rsp, 8

        mov     [SystemTable], rdx

        mov     rax, [rdx + ST_BootServices]
        mov     [BootServices], rax

        mov     rax, [rdx + ST_ConOut]
        mov     [ConOut], rax

        mov     rax, [rdx + ST_ConIn]
        mov     [ConIn], rax

        mov     rcx, [ConOut]
        call    [rcx + ConOut_ClearScreen]

        lea     rcx, [str_hello]
        call    PRINT

        call    OPEN_ROOT
        test    rax, rax
        jnz     .fail

        call    RUN_ALL_OBJ

.menu_loop:
        call    LIST_BIN

        lea     rcx, [str_prompt]
        call    PRINT

        call    READ_NUMBER
        mov     [UserChoice], rax
        test    rax, rax
        jz      .exit

        call    RUN_SELECTED_BIN

        lea     rcx, [str_back]
        call    PRINT
        jmp     .menu_loop

.exit:
        xor     rax, rax
        add     rsp, 8
        ret

.fail:
        lea     rcx, [str_err]
        call    PRINT
        mov     rax, 1
        add     rsp, 8
        ret

; ------------------------------------------------------------------
; PRINT(const CHAR16 *rcx)
; ------------------------------------------------------------------
PRINT:
        push    rbx
        sub     rsp, 8                  ; выравнивание
        mov     rbx, rcx
        mov     rcx, [ConOut]
        mov     rdx, rbx
        call    [rcx + ConOut_OutputString]
        add     rsp, 8
        pop     rbx
        ret

PRINT_CRLF:
        sub     rsp, 8
        lea     rcx, [str_crlf]
        call    PRINT
        add     rsp, 8
        ret

; ------------------------------------------------------------------
; PRINT_NUM(UINT64 rax)
; ------------------------------------------------------------------
PRINT_NUM:
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        sub     rsp, 8                  ; выравнивание (5 push + 8)

        mov     rbx, 10
        xor     rcx, rcx
        lea     rsi, [NumBuf + 31]
        mov     byte [rsi], 0

.pn_div:
        xor     rdx, rdx
        div     rbx
        add     dl, '0'
        dec     rsi
        mov     [rsi], dl
        inc     rcx
        test    rax, rax
        jnz     .pn_div

        lea     rdi, [NumUtf16]
.pn_conv:
        mov     al, [rsi]
        mov     [rdi], al
        mov     byte [rdi+1], 0
        inc     rsi
        add     rdi, 2
        dec     rcx
        jnz     .pn_conv
        mov     word [rdi], 0

        lea     rcx, [NumUtf16]
        call    PRINT

        add     rsp, 8
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; READ_NUMBER -> RAX
; ------------------------------------------------------------------
READ_NUMBER:
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        sub     rsp, 8                  ; выравнивание

        xor     rbx, rbx

.rn_loop:
        mov     rcx, [ConIn]
        lea     rdx, [KeyBuffer]
        call    [rcx + ConIn_ReadKeyStroke]
        test    rax, rax
        jnz     .rn_loop

        movzx   eax, word [KeyBuffer + 2]
        cmp     ax, 13                  ; Enter
        je      .rn_done
        cmp     ax, 8                   ; Backspace
        je      .rn_back
        cmp     ax, '0'
        jb      .rn_loop
        cmp     ax, '9'
        ja      .rn_loop

        ; защита от переполнения: не более 9 цифр
        cmp     rbx, 100000000
        jae     .rn_loop

        mov     [EchoBuf], ax
        mov     word [EchoBuf+2], 0
        lea     rcx, [EchoBuf]
        call    PRINT

        sub     ax, '0'
        movzx   eax, ax
        push    rax
        mov     rax, rbx
        mov     rcx, 10
        mul     rcx
        mov     rbx, rax
        pop     rax
        add     rbx, rax
        jmp     .rn_loop

.rn_back:
        test    rbx, rbx
        jz      .rn_loop
        ; делим на 10
        mov     rax, rbx
        xor     rdx, rdx
        mov     rcx, 10
        div     rcx
        mov     rbx, rax
        ; эхо backspace: \b \b
        mov     word [EchoBuf], 8
        mov     word [EchoBuf+2], 0
        lea     rcx, [EchoBuf]
        call    PRINT
        mov     word [EchoBuf], ' '
        mov     word [EchoBuf+2], 0
        lea     rcx, [EchoBuf]
        call    PRINT
        mov     word [EchoBuf], 8
        mov     word [EchoBuf+2], 0
        lea     rcx, [EchoBuf]
        call    PRINT
        jmp     .rn_loop

.rn_done:
        call    PRINT_CRLF
        mov     rax, rbx

        add     rsp, 8
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; OPEN_ROOT -> RAX = 0 success, 1 fail
; ------------------------------------------------------------------
OPEN_ROOT:
        push    rbx
        push    rcx
        push    rdx
        push    r8
        push    r9
        push    r10
        push    r11
        sub     rsp, 8                  ; выравнивание (7 push + 8 = 16*4)

        mov     qword [FsHandleCount], MAX_FS_HANDLES

        ; EFI_LOCATE_SEARCH_TYPE ByProtocol, GUID, NULL, &count, handles
        sub     rsp, 0x20
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        lea     rax, [FsHandles]
        mov     [rsp + 0x20], rax       ; 5-й аргумент в стеке

        mov     rcx, ByProtocol
        lea     rdx, [EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID]
        xor     r8, r8
        lea     r9, [FsHandleCount]
        mov     rax, [BootServices]
        call    [rax + BS_LocateHandle]

        add     rsp, 0x20

        test    rax, rax
        jnz     .or_fail
        cmp     qword [FsHandleCount], 0
        je      .or_fail

        mov     rcx, [FsHandles]
        mov     rax, [BootServices]
        lea     rdx, [EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID]
        lea     r8, [FsProto]
        call    [rax + BS_HandleProtocol]
        test    rax, rax
        jnz     .or_fail

        mov     rcx, [FsProto]
        lea     rdx, [RootFS]
        call    [rcx + FS_OpenVolume]
        test    rax, rax
        jnz     .or_fail

        xor     rax, rax
        jmp     .or_done

.or_fail:
        mov     rax, 1
.or_done:
        add     rsp, 8
        pop     r11
        pop     r10
        pop     r9
        pop     r8
        pop     rdx
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; MATCH_EXT(RDI = UTF-16 filename, R12 = UTF-16 mask like ".BIN")
; Ищет ПОСЛЕДНЮЮ точку в имени и сравнивает с маской.
; -> RAX = 1 if match, 0 if not
; ------------------------------------------------------------------
MATCH_EXT:
        push    rsi
        push    rdi
        push    rcx
        push    rdx

        mov     rsi, rdi
        xor     rcx, rcx                ; rcx = указатель на последнюю точку

.me_scan:
        mov     ax, [rsi]
        test    ax, ax
        jz      .me_scandone
        cmp     ax, '.'
        jne     .me_next
        mov     rcx, rsi                ; запомнили текущую точку
.me_next:
        add     rsi, 2
        jmp     .me_scan

.me_scandone:
        test    rcx, rcx
        jz      .me_no                  ; точки нет вообще

        mov     rsi, rcx                ; rsi -> последняя точка
        mov     rdi, r12
.me_loop:
        mov     ax, [rsi]
        mov     dx, [rdi]

        test    dx, dx
        jz      .me_yes                 ; маска закончилась -> совпадение
        test    ax, ax
        jz      .me_no                  ; имя закончилось раньше

        ; uppercase для ax
        cmp     ax, 'a'
        jb      .me_u1
        cmp     ax, 'z'
        ja      .me_u1
        sub     ax, 32
.me_u1:
        ; uppercase для dx
        cmp     dx, 'a'
        jb      .me_u2
        cmp     dx, 'z'
        ja      .me_u2
        sub     dx, 32
.me_u2:
        cmp     ax, dx
        jne     .me_no

        add     rsi, 2
        add     rdi, 2
        jmp     .me_loop

.me_yes:
        mov     rax, 1
        jmp     .me_done
.me_no:
        xor     rax, rax
.me_done:
        pop     rdx
        pop     rcx
        pop     rdi
        pop     rsi
        ret

; ------------------------------------------------------------------
; LIST_BIN
; ------------------------------------------------------------------
LIST_BIN:
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        push    r8
        push    r9
        push    r10
        push    r11
        push    r12
        push    r13
        sub     rsp, 8                  ; выравнивание (11 push + 8)

        lea     rcx, [str_menu]
        call    PRINT

        xor     r13, r13

        sub     rsp, 0x20
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rcx, [RootFS]
        lea     rdx, [DirHandle]
        lea     r8, [str_root]
        mov     r9, EFI_FILE_MODE_READ
        call    [rcx + File_Open]
        add     rsp, 0x20
        test    rax, rax
        jnz     .lb_done

.lb_loop:
        mov     qword [FileInfoBuf], 0
        mov     rax, [BootServices]
        mov     rcx, EfiLoaderData
        mov     rdx, FILE_INFO_BUF_SIZE
        lea     r8, [FileInfoBuf]
        call    [rax + BS_AllocatePool]
        test    rax, rax
        jnz     .lb_close

        mov     qword [FileInfoSize], FILE_INFO_BUF_SIZE

        mov     rcx, [DirHandle]
        lea     rdx, [FileInfoSize]
        mov     r8, [FileInfoBuf]
        call    [rcx + File_Read]
        test    rax, rax
        jnz     .lb_free_and_close

        cmp     qword [FileInfoSize], 0
        je      .lb_free_and_close

        mov     rsi, [FileInfoBuf]
        mov     eax, [rsi + FI_Attribute]
        test    eax, EFI_FILE_DIRECTORY
        jnz     .lb_free

        lea     rdi, [rsi + FI_FileName]
        lea     r12, [str_dot_bin]
        call    MATCH_EXT

        test    rax, rax
        jz      .lb_free

        inc     r13

        mov     rax, r13
        call    PRINT_NUM
        lea     rcx, [str_space]
        call    PRINT

        mov     rsi, [FileInfoBuf]
        lea     rcx, [rsi + FI_FileName]
        call    PRINT

        call    PRINT_CRLF

.lb_free:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0
        jmp     .lb_loop

.lb_free_and_close:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0

.lb_close:
        mov     rcx, [DirHandle]
        call    [rcx + File_Close]

.lb_done:
        add     rsp, 8
        pop     r13
        pop     r12
        pop     r11
        pop     r10
        pop     r9
        pop     r8
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; LOAD_FILE(RDI = UTF-16 filename) -> RAX = buffer, RDX = size
;                                   RAX = 0 при ошибке
; ------------------------------------------------------------------
LOAD_FILE:
        push    rbx
        push    rcx
        push    rsi
        push    rdi
        push    r8
        push    r9
        push    r10
        push    r11
        push    r12
        push    r13
        sub     rsp, 8                  ; выравнивание (10 push + 8)

        mov     r12, rdi

        mov     qword [LoadFileInfoBuf], 0
        mov     qword [LoadBuffer], 0
        mov     qword [LoadBufferSize], 0
        mov     qword [FileHandle], 0

        mov     rax, [BootServices]
        mov     rcx, EfiLoaderData
        mov     rdx, FILE_INFO_BUF_SIZE
        lea     r8, [LoadFileInfoBuf]
        call    [rax + BS_AllocatePool]
        test    rax, rax
        jnz     .lf_fail_early

        mov     qword [FileInfoSize], FILE_INFO_BUF_SIZE

        sub     rsp, 0x20
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rcx, [RootFS]
        lea     rdx, [FileHandle]
        mov     r8, r12
        mov     r9, EFI_FILE_MODE_READ
        call    [rcx + File_Open]
        add     rsp, 0x20
        test    rax, rax
        jnz     .lf_fail

        mov     rcx, [FileHandle]
        lea     rdx, [EFI_FILE_INFO_GUID]
        lea     r8, [FileInfoSize]
        mov     r9, [LoadFileInfoBuf]
        call    [rcx + File_GetInfo]
        test    rax, rax
        jnz     .lf_fail

        mov     rsi, [LoadFileInfoBuf]
        mov     rdx, [rsi + FI_FileSize]
        mov     [LoadBufferSize], rdx

        ; защита от нулевого размера
        test    rdx, rdx
        jz      .lf_fail

        mov     rax, [BootServices]
        mov     rcx, EfiLoaderData
        mov     rdx, [LoadBufferSize]
        add     rdx, 4095
        and     rdx, -4096
        lea     r8, [LoadBuffer]
        call    [rax + BS_AllocatePool]
        test    rax, rax
        jnz     .lf_fail

        mov     rcx, [FileHandle]
        lea     rdx, [LoadBufferSize]
        mov     r8, [LoadBuffer]
        call    [rcx + File_Read]
        test    rax, rax
        jnz     .lf_fail

        mov     rcx, [FileHandle]
        call    [rcx + File_Close]
        mov     qword [FileHandle], 0

        mov     rax, [BootServices]
        mov     rcx, [LoadFileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [LoadFileInfoBuf], 0

        mov     rax, [LoadBuffer]
        mov     rdx, [LoadBufferSize]
        jmp     .lf_done

.lf_fail:
        ; закрыть файл, если открыт
        cmp     qword [FileHandle], 0
        je      .lf_fail_noclose
        mov     rcx, [FileHandle]
        call    [rcx + File_Close]
        mov     qword [FileHandle], 0
.lf_fail_noclose:
        ; освободить LoadBuffer, если выделен
        cmp     qword [LoadBuffer], 0
        je      .lf_fail_nobuf
        mov     rax, [BootServices]
        mov     rcx, [LoadBuffer]
        call    [rax + BS_FreePool]
        mov     qword [LoadBuffer], 0
.lf_fail_nobuf:

.lf_fail_early:
        ; освободить LoadFileInfoBuf, если выделен
        cmp     qword [LoadFileInfoBuf], 0
        je      .lf_fail_done
        mov     rax, [BootServices]
        mov     rcx, [LoadFileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [LoadFileInfoBuf], 0
.lf_fail_done:
        xor     rax, rax
        xor     rdx, rdx

.lf_done:
        add     rsp, 8
        pop     r13
        pop     r12
        pop     r11
        pop     r10
        pop     r9
        pop     r8
        pop     rdi
        pop     rsi
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; RUN_BINARY(RAX = entry point)
; Сохраняет callee-saved регистры вокруг вызова.
; ------------------------------------------------------------------
RUN_BINARY:
        push    rbx
        push    rbp
        push    rdi
        push    rsi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 8                  ; выравнивание (8 push + 8 = 16*5)

        mov     rbx, rax
        call    rbx

        add     rsp, 8
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rsi
        pop     rdi
        pop     rbp
        pop     rbx
        ret

; ------------------------------------------------------------------
; RUN_SELECTED_BIN
; ------------------------------------------------------------------
RUN_SELECTED_BIN:
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        push    r8
        push    r9
        push    r10
        push    r11
        push    r12
        push    r13
        sub     rsp, 8                  ; выравнивание

        xor     r13, r13
        mov     rbx, [UserChoice]

        sub     rsp, 0x20
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rcx, [RootFS]
        lea     rdx, [DirHandle]
        lea     r8, [str_root]
        mov     r9, EFI_FILE_MODE_READ
        call    [rcx + File_Open]
        add     rsp, 0x20
        test    rax, rax
        jnz     .rsb_done

.rsb_loop:
        mov     qword [FileInfoBuf], 0
        mov     rax, [BootServices]
        mov     rcx, EfiLoaderData
        mov     rdx, FILE_INFO_BUF_SIZE
        lea     r8, [FileInfoBuf]
        call    [rax + BS_AllocatePool]
        test    rax, rax
        jnz     .rsb_close

        mov     qword [FileInfoSize], FILE_INFO_BUF_SIZE

        mov     rcx, [DirHandle]
        lea     rdx, [FileInfoSize]
        mov     r8, [FileInfoBuf]
        call    [rcx + File_Read]
        test    rax, rax
        jnz     .rsb_free_and_close

        cmp     qword [FileInfoSize], 0
        je      .rsb_free_and_close

        mov     rsi, [FileInfoBuf]
        mov     eax, [rsi + FI_Attribute]
        test    eax, EFI_FILE_DIRECTORY
        jnz     .rsb_free

        lea     rdi, [rsi + FI_FileName]
        lea     r12, [str_dot_bin]
        call    MATCH_EXT

        test    rax, rax
        jz      .rsb_free

        inc     r13
        cmp     r13, rbx
        jne     .rsb_free

        lea     rcx, [str_bin_run]
        call    PRINT
        mov     rsi, [FileInfoBuf]
        lea     rcx, [rsi + FI_FileName]
        call    PRINT
        call    PRINT_CRLF

        mov     rdi, [FileInfoBuf]
        lea     rdi, [rdi + FI_FileName]
        call    LOAD_FILE
        test    rax, rax
        jz      .rsb_free

        call    RUN_BINARY

        mov     rax, [BootServices]
        mov     rcx, [LoadBuffer]
        call    [rax + BS_FreePool]
        mov     qword [LoadBuffer], 0

.rsb_free:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0
        jmp     .rsb_loop

.rsb_free_and_close:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0

.rsb_close:
        mov     rcx, [DirHandle]
        call    [rcx + File_Close]

.rsb_done:
        add     rsp, 8
        pop     r13
        pop     r12
        pop     r11
        pop     r10
        pop     r9
        pop     r8
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        ret

; ------------------------------------------------------------------
; RUN_ALL_OBJ
; ------------------------------------------------------------------
RUN_ALL_OBJ:
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        push    r8
        push    r9
        push    r10
        push    r11
        push    r12
        sub     rsp, 8                  ; выравнивание (10 push + 8)

        sub     rsp, 0x20
        mov     qword [rsp], 0
        mov     qword [rsp + 8], 0
        mov     qword [rsp + 16], 0
        mov     qword [rsp + 24], 0
        mov     rcx, [RootFS]
        lea     rdx, [DirHandle]
        lea     r8, [str_root]
        mov     r9, EFI_FILE_MODE_READ
        call    [rcx + File_Open]
        add     rsp, 0x20
        test    rax, rax
        jnz     .rao_done

.rao_loop:
        mov     qword [FileInfoBuf], 0
        mov     rax, [BootServices]
        mov     rcx, EfiLoaderData
        mov     rdx, FILE_INFO_BUF_SIZE
        lea     r8, [FileInfoBuf]
        call    [rax + BS_AllocatePool]
        test    rax, rax
        jnz     .rao_close

        mov     qword [FileInfoSize], FILE_INFO_BUF_SIZE

        mov     rcx, [DirHandle]
        lea     rdx, [FileInfoSize]
        mov     r8, [FileInfoBuf]
        call    [rcx + File_Read]
        test    rax, rax
        jnz     .rao_free_and_close

        cmp     qword [FileInfoSize], 0
        je      .rao_free_and_close

        mov     rsi, [FileInfoBuf]
        mov     eax, [rsi + FI_Attribute]
        test    eax, EFI_FILE_DIRECTORY
        jnz     .rao_free

        lea     rdi, [rsi + FI_FileName]
        lea     r12, [str_dot_obj]
        call    MATCH_EXT

        test    rax, rax
        jz      .rao_free

        lea     rcx, [str_obj_run]
        call    PRINT
        mov     rsi, [FileInfoBuf]
        lea     rcx, [rsi + FI_FileName]
        call    PRINT
        call    PRINT_CRLF

        mov     rdi, [FileInfoBuf]
        lea     rdi, [rdi + FI_FileName]
        call    LOAD_FILE
        test    rax, rax
        jz      .rao_free

        call    RUN_BINARY

        mov     rax, [BootServices]
        mov     rcx, [LoadBuffer]
        call    [rax + BS_FreePool]
        mov     qword [LoadBuffer], 0

.rao_free:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0
        jmp     .rao_loop

.rao_free_and_close:
        mov     rax, [BootServices]
        mov     rcx, [FileInfoBuf]
        call    [rax + BS_FreePool]
        mov     qword [FileInfoBuf], 0

.rao_close:
        mov     rcx, [DirHandle]
        call    [rcx + File_Close]

.rao_done:
        add     rsp, 8
        pop     r12
        pop     r11
        pop     r10
        pop     r9
        pop     r8
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        ret