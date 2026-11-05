ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

PHDRS
{
    all PT_LOAD FLAGS(7);
}

SECTIONS
{
    . = 0x00000000;
    .text : { *(.text*) } > RAM :all
    .rodata : { *(.rodata*) } > RAM :all
    .sdata : { *(.sdata*) } > RAM :all
    .data : { *(.data*) } > RAM :all
    .bss : { *(.bss*) *(COMMON) } > RAM :all
    _stack_top = ORIGIN(RAM) + LENGTH(RAM) - 64;

    /DISCARD/ : {
        *(.note.*)
        *(.eh_frame*)
        *(.riscv.attributes*)
        *(.comment*)
    }
}
