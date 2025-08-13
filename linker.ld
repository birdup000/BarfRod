OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Use traditional kernel mapping at 1MB */
__KERNEL_VMA = 0;

PHDRS
{
  text PT_LOAD FLAGS((1 << 0) | (1 << 2));   /* R | X */
  rodata PT_LOAD FLAGS((1 << 2));            /* R */
  data PT_LOAD FLAGS((1 << 1) | (1 << 2));   /* R | W */
}

SECTIONS
{
  /* Link with VMA at higher half and LMA at physical 1MiB so bootloader can load it */
  . = 1M;
  __KERNEL_START_PHYS = .;

  /* Multiboot2 header must be at exactly 1MiB */
  .multiboot2 :
  {
    KEEP(*(.multiboot2))
  } :text

  /* Multiboot header for backward compatibility */
  .multiboot :
  {
    KEEP(*(.multiboot))
  } :text

  /* Adjust VMA to higher half */
  . += __KERNEL_VMA;
  _kernel_start_vaddr = .;

  /* Start text section after multiboot header */
  .text :
  ALIGN(4K)
  {
    _text_start = .;
    KEEP(*(.text.boot))
    *(.text .text.*)
    _text_end = .;
  } :text

  .rodata : AT(ADDR(.rodata) - __KERNEL_VMA)
  ALIGN(4K)
  {
    _rodata_start = .;
    *(.rodata .rodata.*)
    _rodata_end = .;
  } :rodata

  .data : AT(ADDR(.data) - __KERNEL_VMA)
  ALIGN(4K)
  {
    _data_start = .;
    *(.data .data.*)
    _data_end = .;
  } :data

  .bss (NOLOAD) : AT(ADDR(.bss) - __KERNEL_VMA)
  ALIGN(4K)
  {
    _bss_start = .;
    *(COMMON)
    *(.bss .bss.*)
    _bss_end = .;
  } :data

  _kernel_end_vaddr = .;
  __KERNEL_END_PHYS = _kernel_end_vaddr - __KERNEL_VMA;

  /DISCARD/ :
  {
    *(.eh_frame .eh_frame.*)
    *(.comment)
    *(.gcc_except_table)
  }
}