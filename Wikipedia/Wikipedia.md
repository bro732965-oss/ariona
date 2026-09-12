

UEFI Mini-OS (NASM)

UEFI Mini-OS is a minimal x86-64 operating system loader and microkernel written entirely in NASM assembly. It runs as a UEFI application (BOOTX64.EFI) on modern PCs and boots from USB flash drives or internal disks. It provides a text menu of *.bin files, automatically executes all *.obj files from the root of the boot volume, and runs them in ring 0 under long mode. It contains no C code, no libc, and no external dependencies other than the UEFI firmware.

{{Infobox OS
| name = UEFI Mini-OS
| logo =
| screenshot =
| caption = UEFI Mini-OS boot menu
| developer = (author/community)
| source_model = Open source
| released = 2026
| latest_release_version = 1.0
| latest_release_date = 2026
| marketing_target = Hobbyist, educational, embedded
| programmed_in = NASM assembly (x86-64)
| kernel_type = Monolithic
| license = (specify)
| supported_platforms = x86-64 (Intel Core, AMD64)
| ui = Text menu (UEFI Simple Text Output)
| bootloader = UEFI application (BOOTX64.EFI)
}}

Contents

1. Overview
2. History
3. Design
   3.1 Boot process
   3.2 Memory model
   3.3 File system access
   3.4 Program model
4. Features
5. Limitations
6. Build process
7. Deployment
8. Security
9. Comparison with other systems
10. See also
11. References
12. External links

Overview

UEFI Mini-OS is a single-address-space, single-tasking operating environment that runs directly on UEFI firmware. It is not a full operating system in the traditional sense: it does not implement processes, virtual memory, scheduling, or device drivers beyond what UEFI provides. Instead, it acts as a loader and runtime host for flat 64-bit binaries stored on a FAT32 volume.

The system is written entirely in NASM assembly and linked with x86_64-w64-mingw32-ld into a PE32+ executable named BOOTX64.EFI. It uses the Microsoft x64 calling convention, which is also the ABI used by UEFI on x86-64.

History

The project began as a DOS .COM program that scanned the current directory for *.obj files and executed them via INT 21h, AH=4Bh. It later evolved into a FAT12 floppy boot sector targeting real mode. The current version abandons BIOS and real mode entirely and uses UEFI Boot Services.

Key milestones:

· DOS version — used INT 21h functions 4Eh, 4Fh, 4Ah, 4Bh.
· Real-mode boot sector — FAT12, INT 13h, INT 10h, INT 16h, loaded at 0x7C00.
· UEFI version (current) — PE32+, long mode, EFI_SIMPLE_FILE_SYSTEM_PROTOCOL, EFI_FILE_PROTOCOL.

Design

Boot process

1. UEFI firmware reads the GPT partition table.
2. It locates the EFI System Partition (ESP), formatted as FAT32.
3. It loads \EFI\BOOT\BOOTX64.EFI.
4. The loader receives EFI_HANDLE in RCX and EFI_SYSTEM_TABLE* in RDX.
5. It calls BootServices->LocateHandle with SearchType = ByProtocol and the EFI_SIMPLE_FILE_SYSTEM_PROTOCOL GUID.
6. It obtains the protocol via HandleProtocol.
7. It opens the root volume with OpenVolume.
8. It enumerates the root directory and matches file extensions.
9. It loads and executes *.obj files first.
10. It displays a menu of *.bin files and waits for user input.

Memory model

· Runs in long mode (64-bit).
· Uses the Microsoft x64 calling convention.
· Single address space; no paging changes by the loader.
· Programs are loaded into memory allocated by BootServices->AllocatePool with type EfiLoaderData.
· Each loaded program is invoked with call and must return with ret.

File system access

The loader does not implement a file system. It relies entirely on the UEFI EFI_SIMPLE_FILE_SYSTEM_PROTOCOL, which the firmware implements for FAT32 (and sometimes other file systems). Directory enumeration is performed with EFI_FILE_PROTOCOL.Read, which returns EFI_FILE_INFO structures.

The EFI_FILE_INFO structure layout is:

Offset Field
0x00 Size
0x08 FileSize
0x10 PhysicalSize
0x18 CreateTime
0x20 LastAccessTime
0x28 ModificationTime
0x30 Attribute
0x38 FileName (UTF-16LE)

Note: In the current implementation, Attribute is read at 0x48 and FileName at 0x50. These offsets are correct for UEFI 2.x on x86-64 with the standard 8-byte alignment of UINT64 fields. On some firmware revisions the offsets may differ.

Program model

Programs are flat 64-bit binaries. They are not PE or ELF files. They are loaded at an arbitrary address and invoked with call. The calling convention is Microsoft x64, though the loader does not pass arguments: RCX, RDX, R8, and R9 are undefined on entry.

A minimal program is:

```asm
        BITS 64
        DEFAULT REL

program_entry:
        ret
```

Programs must not:

· modify the GDT or IDT,
· disable interrupts permanently,
· assume a specific load address,
· call UEFI Boot Services unless they saved the SystemTable pointer themselves.

Programs may:

· use any x86-64 instruction,
· read and write their own memory,
· call other code within their own image,
· return to the loader with ret.

Features

· Autostart of all *.obj files on the boot volume.
· Interactive menu of *.bin files with numeric selection.
· Return to menu after each program terminates via ret.
· Exit to UEFI Boot Manager when 0 is entered.
· No C runtime, no libc, no external dependencies.
· FAT32 support via UEFI firmware.
· Long mode (64-bit) execution.
· English-only interface.

Limitations

· Single-tasking. No processes, no scheduling, no threads.
· No memory protection. All code runs in ring 0 with full access.
· No paging control. The loader does not modify page tables.
· No file system implementation. Relies on UEFI for FAT32.
· No drivers. No networking, no audio, no graphics beyond UEFI text output.
· Secure Boot must be disabled or the binary must be signed.
· Programs must return with ret. A program that hangs will hang the system.
· No arguments passed to programs. Programs are invoked with undefined register state.
· Load address is not fixed. Programs must be position-independent.
· No error recovery. A faulting program will typically reset the machine.

Build process

Requirements:

· NASM
· GNU ld with PE support (x86_64-w64-mingw32-ld)

Commands:

```bash
nasm -f win64 bootx64.asm -o bootx64.obj

x86_64-w64-mingw32-ld -nostdlib \
    -Wl,-entry,efi_main \
    -Wl,-subsystem,10 \
    -Wl,-file-alignment,0x200 \
    -Wl,-section-alignment,0x1000 \
    bootx64.obj -o BOOTX64.EFI
```

The resulting file is a PE32+ executable with subsystem EFI Application (10).

Deployment

1. Format a USB flash drive as FAT32 with a GPT partition table.
2. Create the directory \EFI\BOOT\.
3. Copy BOOTX64.EFI to \EFI\BOOT\.
4. Copy *.bin and *.obj files to the root of the volume.
5. Disable Secure Boot and CSM in UEFI settings.
6. Boot from the USB drive.

Security

UEFI Mini-OS does not implement any security mechanisms:

· No memory isolation.
· No privilege separation.
· No signature verification of loaded programs.
· No sandboxing.

It is intended for educational and hobbyist use only. Running untrusted code under UEFI Mini-OS is equivalent to running it as firmware.

Comparison with other systems

System Mode Filesystem Multi-tasking Memory protection Language
UEFI Mini-OS Long mode FAT32 via UEFI No No NASM
DOS Real mode FAT12/16 No No ASM/C
Linux Long mode ext4, FAT32, etc. Yes Yes C
KolibriOS 32-bit FAT32, ext2 Yes Partial ASM/C
MenuetOS 32/64-bit FAT32 Yes Partial ASM

See also

· UEFI
· EFI System Partition
· PE32+
· Long mode
· NASM
· FAT32
· Bootloader
· Microkernel
· KolibriOS
· MenuetOS

References

1. UEFI Specification, Version 2.10, Unified EFI Forum.
2. Microsoft PE and COFF Specification.
3. Intel 64 and IA-32 Architectures Software Developer's Manual.
4. NASM Manual.

External links

· UEFI Forum — official specification
· NASM — assembler used
· GNU binutils — linker used

---

Categories: Operating systems | x86-64 operating systems | UEFI | Assembly language | Hobbyist operating systems | Boot loaders