OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS((1 << 0) | (1 << 2));   /* R | X */
  rodata PT_LOAD FLAGS((1 << 2));            /* R */
  data PT_LOAD FLAGS((1 << 1) | (1 << 2));   /* R | W */
}

SECTIONS
{
  /* Start at physical 1MiB for multiboot */
  . = 1M;
  
  /* Multiboot2 header must be at exactly 1MiB */
  .multiboot2 : {
    KEEP(*(.multiboot2))
  } :text

  /* Multiboot header for backward compatibility */
  .multiboot : {
    KEEP(*(.multiboot))
  } :text

  /* Text section */
  .text : {
    _text_start = .;
    KEEP(*(.text.boot))
    *(.text .text.*)
    _text_end = .;
  } :text

  /* Read-only data */
  .rodata : {
    _rodata_start = .;
    *(.rodata .rodata.*)
    _rodata_end = .;
  } :rodata

  /* Data section */
  .data : {
    _data_start = .;
    *(.data .data.*)
    _data_end = .;
  } :data

  /* BSS section */
  .bss (NOLOAD) : {
    _bss_start = .;
    *(COMMON)
    *(.bss .bss.*)
    _bss_end = .;
  } :data

  _kernel_end = .;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame.*)
    *(.comment)
    *(.gcc_except_table)
  }
}