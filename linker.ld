OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
  headers PT_LOAD FLAGS((1 << 0) | (1 << 2)); /* R | X - for multiboot headers at file offset 0 */
  text PT_LOAD FLAGS((1 << 0) | (1 << 2));    /* R | X */
  rodata PT_LOAD FLAGS((1 << 2));             /* R */
  data PT_LOAD FLAGS((1 << 1) | (1 << 2));    /* R | W */
}

SECTIONS
{
  /* 
   * The multiboot2 header MUST be within the first 8192 bytes of the file.
   * We place it at file offset 0 using AT(), but it will be loaded at 0x100000.
   */
  . = 0x100000;

  /* Multiboot header - placed at file offset 0 */
  .multiboot : AT(0) {
    KEEP(*(.multiboot))
    . = ALIGN(8);
  } :headers

  /* Text section - placed after multiboot header in file, at 0x100000+ in memory */
  .text : AT(SIZEOF(.multiboot)) {
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
