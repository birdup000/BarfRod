OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Use direct mapping for now - no higher half */
__KERNEL_VMA = 0;

PHDRS
{
  text PT_LOAD FLAGS((1 << 0) | (1 << 2));   /* R | X */
  rodata PT_LOAD FLAGS((1 << 2));            /* R */
  data PT_LOAD FLAGS((1 << 1) | (1 << 2));   /* R | W */
}

SECTIONS
{
  /* Link with VMA and LMA at physical 1MiB so bootloader can load it */
  . = 1M;

  _kernel_start_vaddr = .;

  /* Multiboot header must be at exactly 1MiB */
  .multiboot :
  {
    . = ALIGN(4);
    KEEP(*(.multiboot))
    /* Ensure section is exactly 12 bytes (multiboot header size) */
    . = . + 12;
  } :text

  /* Start text section after multiboot header */
  .text :
  ALIGN(4K)
  {
    _text_start = .;
    KEEP(*(.text.boot))
    *(.text .text.*)
    _text_end = .;
  } :text

  .rodata : AT(ADDR(.rodata))
  ALIGN(4K)
  {
    _rodata_start = .;
    *(.rodata .rodata.*)
    _rodata_end = .;
  } :rodata

  .data : AT(ADDR(.data))
  ALIGN(4K)
  {
    _data_start = .;
    *(.data .data.*)
    _data_end = .;
  } :data

  .bss (NOLOAD) : AT(ADDR(.bss))
  ALIGN(4K)
  {
    _bss_start = .;
    *(COMMON)
    *(.bss .bss.*)
    _bss_end = .;
  } :data

  _kernel_end_vaddr = .;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame.*)
    *(.comment)
    *(.gcc_except_table)
  }
}