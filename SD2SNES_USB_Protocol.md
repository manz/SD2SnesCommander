# SD2SNES USB Protocol Documentation

## Overview

The SD2SNES uses a custom USB protocol built on top of CDC (Communication Device Class). The protocol uses a packet-based interface where operations consist of command-response pairs, with optional data transfers.

## Packet Structure

All packets are 512 bytes. Shorter payloads are padded with zeros. The
command buffer mirrors the response layout for simplicity.

### USB Command Format (host → device, 512 bytes)

| Offset | Length | Contents |
|--------|--------|----------|
| 0      | 4      | Magic: `'USBA'` |
| 4      | 1      | Opcode |
| 5      | 1      | Space |
| 6      | 1      | Flags |
| 7      | 1      | Reserved (0) |
| 8      | 24     | Opcode-specific payload (e.g. TIME fields at 8-14, MV new filename at 8+) |
| 32     | 32     | VGET/VPUT vector table — 8 × 4-byte entries: `[size, addr_hi, addr_mid, addr_lo]` |
| 64     | 188    | Reserved / padding |
| 252    | 4      | Size field (U32BE). Semantics vary: file_size for PUT, byte count for GET/VGET/VPUT, unused for control ops |
| 256    | 256    | Null-terminated string parameter (path for FILE-space ops). For non-FILE spaces the low 24 bits of offset 256-259 encode the starting address (big-endian). |

### USB Response Format (device → host, 512 bytes)

Baseline layout for every response:

| Offset | Length | Contents |
|--------|--------|----------|
| 0      | 4      | Magic: `'USBA'` |
| 4      | 1      | Opcode = 0x0F (RESPONSE) |
| 5      | 1      | Error code (0 = success) |
| 6-251  | 246    | Zero for most ops. INFO and the data-stream ops use this region (see below) |
| 252    | 4      | `total_size` (U32BE). Echoes the cmd size field for PUT, reports actual data length for GET/VGET, placeholder `1` for LS, `0` for control ops |
| 256-511| 256    | Op-specific payload (INFO only, otherwise zero) |

## Operation Details

### Response vs Data Transfer Operations

**Operations that send response + data blocks:**
- GET, VGET, LS, STREAM

**Operations that receive data blocks after response:**
- PUT, VPUT

**Operations that send response only:**
- MKDIR, RM, MV, RESET, BOOT, POWER_CYCLE, INFO, MENU_RESET, TIME

### Response Suppression
Any operation can suppress the response packet by setting the `NORESP` flag (64). For data transfer operations, the first data block is sent immediately instead of a response.

## Operations

### 1. GET (0x00) - Read Data
**Purpose:** Read data from various spaces (file system, SNES memory, MSU, configuration)

**Inputs:**
- **Space:** FILE, SNES, MSU, CMD, CONFIG, CFG
- **Size:** Number of bytes to read (for non-FILE spaces)
- **Offset:** Starting address (for non-FILE spaces, offset 256-259)
- **String Parameter:** File path (for FILE space) or config key (for CFG space)

**Supported Flags:**
- `64BDATA` (128): Use 64-byte data blocks instead of 512-byte
- `NORESP` (64): Skip response packet, send data immediately
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation

**Response Format:**
- Standard response header with `total_size` set to actual data size

**Data Block Format:**
- **FILE/CFG Space:** Raw file/config data
- **SNES/MSU/CMD Space:** Raw memory data
- **CONFIG Space:** Single byte containing register value

**Space-specific behavior:**
- **FILE:** Uses `f_stat()` to get file size, `f_open()` to read file. Size is determined automatically from file.
- **SNES:** Reads from SNES SRAM using `sram_readblock()` starting at specified offset
- **MSU:** Reads MSU1 data using `msu_readblock()` starting at specified offset
- **CMD:** Reads SNES command region using `snescmd_readblock()` starting at specified offset
- **CONFIG:** Reads single FPGA configuration register. Size encodes group, offset encodes index.
- **CFG:** Reads configuration string value. Returns null-terminated string.

### 2. PUT (0x01) - Write Data
**Purpose:** Write data to various spaces

**Inputs:**
- **Space:** FILE, SNES, CMD, CONFIG
- **Size:** Number of bytes to write
- **Offset:** Starting address (for non-file spaces, offset 256-259)
- **String Parameter:** File path (for FILE space)
- **Data Blocks:** Data to write (sent after command is acknowledged)

**Supported Flags:**
- `64BDATA` (128): Use 64-byte data blocks instead of 512-byte
- `NORESP` (64): Skip response packet
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation

**Response Format:**
- Standard response header. `total_size` echoes the client-supplied size
  field from the command (i.e. `file_size` for FILE space, byte count for
  other spaces).

**Data Block Format:**
- Raw binary data in full `block_size` blocks (512 or 64 bytes).
- **The last block must be padded to a full block.** Firmware aggregates
  bytes per block before writing — a short final packet leaves it waiting
  in `HANDLE_LOCK` and the next command will time out. Firmware only
  persists `file_size` bytes to disk regardless of padding.

**Space-specific behavior:**
- **FILE:** Creates/overwrites file using `f_open()` with `FA_WRITE | FA_CREATE_ALWAYS`
- **SNES:** Writes to SRAM using `sram_writeblock()` starting at specified offset
- **CMD:** Writes to command region using `snescmd_writeblock()` starting at specified offset
- **CONFIG:** Writes FPGA config using `fpga_write_config()`. Uses packed format: size=group, offset bits 0-7=index, bits 8-15=data, bits 16-23=invmask

### 3. VGET (0x02) - Vector Read
**Purpose:** Read multiple non-contiguous memory regions

**Inputs:**
- **Space:** SNES, MSU, CMD, CONFIG (not FILE)
- **Vector Data:** 8 entries at offset 32, each containing:
  - Byte 0: Size to read
  - Bytes 1-3: Address (24-bit, big endian)

**Outputs:**
- **Response:** Status and total data size
- **Data Blocks:** Concatenated data from all vector entries

**Notes:** Processes up to 8 vector entries sequentially, returning all data concatenated in order.

### 4. VPUT (0x03) - Vector Write
**Purpose:** Write to multiple non-contiguous memory regions

**Inputs:**
- **Space:** SNES, CMD, CONFIG (not FILE)
- **Vector Data:** 8 entries like VGET
- **Data Blocks:** Data to write to each vector entry

**Outputs:**
- **Response:** Status only

**Notes:** Writes data sequentially to each vector entry, automatically advancing when current entry is complete.

### 5. LS (0x04) - List Directory
**Purpose:** List directory contents

**Inputs:**
- **String Parameter:** Directory path

**Supported Flags:**
- `64BDATA` (128): Use 64-byte data blocks instead of 512-byte
- `NORESP` (64): Skip response packet, send data immediately
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation

**Response Format:**
- Standard response header. `total_size` is **always 1** — a placeholder, not
  the number of entries. The client cannot know the size of the listing in
  advance and must read data blocks until it sees the `0xFF` terminator.

**Data Block Format:**
Each data block is `block_size` bytes (512 default, 64 if `64BDATA`). Inside
a block, entries are tightly packed:
- **1 byte:** Entry type
  - `0`: Directory
  - `1`: File
  - `2`: Continuation — current filename continues in the next block; no
    trailing NUL in this block, resume reading bytes after the type=2
    marker until a NUL is seen
  - `0xFF`: End of listing (no name follows)
- **Variable bytes:** Null-terminated filename (only for type 0 / 1 / 2)

**Notes:**
- Prefers long filenames when available; falls back to 8.3 names (lowercased)
- Skips volume labels
- Multiple entries typically pack into one block
- **No size, date, or attribute data** — firmware has `fi.fsize` / `fi.fdate`
  / `fi.ftime` available but does not emit them. Getting those requires a
  firmware patch (e.g. a new `LS_EX` opcode) or a per-file GET to read
  `total_size` from the response header.

### 6. MKDIR (0x05) - Create Directory
**Purpose:** Create directory

**Inputs:**
- **String Parameter:** Directory path to create

**Outputs:**
- **Response:** Status only

### 7. RM (0x06) - Remove File/Directory
**Purpose:** Remove file or directory

**Inputs:**
- **String Parameter:** Path to remove

**Outputs:**
- **Response:** Status only

### 8. MV (0x07) - Move/Rename File
**Purpose:** Move/rename file

**Inputs:**
- **String Parameter:** Original file path
- **Offset 8:** New filename (appended to original path's directory)

**Outputs:**
- **Response:** Status only

**Notes:** Extracts directory from original path, appends new filename, uses `f_rename()`.

### 9. RESET (0x08) - Reset SNES
**Purpose:** Reset SNES console

**Inputs:** None

**Outputs:**
- **Response:** Status only
- **Return Code:** `SNES_CMD_RESET` to main loop

### 10. BOOT (0x09) - Load and Boot ROM
**Purpose:** Load a ROM file and transition the device into game mode

**Inputs:**
- **String Parameter:** ROM file path (relative to SD card root)

**Supported Flags:**
- `SKIPRESET` (1): Don't release reset after loading ROM
- `ONLYRESET` (2): Only release reset, don't load ROM (use with previously loaded ROM)
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation
- `NORESP` (64): Skip response packet

**Response Format:**
- Standard response header with `total_size` = 0. **Response is sent
  after the ROM is loaded and FPGA reconfigured**, so `receive_response`
  may take several seconds.

**Behavior:**
- If not `ONLYRESET`: Loads ROM file, configures SRAM and FPGA, adds to recent games
- If not `SKIPRESET`: Releases SNES reset and enters game loop
- Returns `SNES_CMD_GAMELOOP` to main loop when entering game mode

**Post-boot state (clients must handle):**
- `usbint_handler` is now driven by the game loop instead of
  `menu_main_loop`. Memory-space ops (GET/VGET on `SNES`/`MSU`/`CMD`)
  continue to work.
- File-system ops (LS, GET/PUT on FILE, BOOT, MENU_RESET response read)
  become unreliable due to SD card SPI contention with SRAM bridging.
- `current_filename` in INFO now reports the loaded ROM path — clients
  use this to detect game mode.

### 11. POWER_CYCLE (0x0A) - Reset Device
**Purpose:** Hard-reset the SD2SNES microcontroller

**Inputs:** None

**Outputs:**
- **Response:** Standard header — firmware builds and sends it before the
  reset. The host may or may not read it depending on timing.
- After the response, firmware calls `NVIC_SystemReset()`
  (`usbinterface.c:771`). The MCU reboots and USB re-enumerates.

**Notes:** Unlike `MENU_RESET`, this *does* reset the MCU. Expect the USB
device to disappear and come back on the host side. The client should
disconnect and rediscover.

### 12. INFO (0x0B) - Get Device Information
**Purpose:** Report firmware version, feature flags, and currently loaded ROM

**Inputs:** None

**Supported Flags:**
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation
- `NORESP` (64): Skip response packet

**Response Format:**
The 512-byte response is fully populated (unlike most ops which leave
everything after offset 5 zero):

| Offset  | Length | Contents |
|---------|--------|----------|
| 0-3     | 4      | Magic `'USBA'` |
| 4       | 1      | Opcode 0x0F (RESPONSE) |
| 5       | 1      | Error code |
| 6-7     | 2      | FPGA feature flags (U16LE) |
| 8-9     | 2      | Reserved (0) |
| 10-11   | 2      | System config flags (U16LE) — bit 0: in-game hook, bit 1: save states |
| 12-15   | 4      | Reserved (0) |
| 16-251  | 236    | Current ROM filename, null-terminated (see below for paths) |
| 252-255 | 4      | `total_size` = 0 |
| 256-259 | 4      | Firmware version magic (`CONFIG_FWVER`, U32BE) |
| 260-323 | 64     | Firmware version string (e.g. `"v1.11.1"`, null-terminated) |
| 324-387 | 64     | Device name (e.g. `"sd2snes Mk.II"`, `"FXPAK PRO STM32"`) |

**Detecting menu vs game mode via INFO:**
- Menu loaded: `current_filename` matches the platform's menu binary:
  - `/sd2snes/menu.bin` on Mk2
  - `/sd2snes/m3nu.bin` on Mk3 / FXPAK PRO STM32
- Otherwise: a ROM is running, game mode is active.
- Recommended detection: suffix match on `menu.bin` / `m3nu.bin`.

**Notes:**
- Only operation with a fully-populated 512-byte response
- INFO is serviceable in both menu and game mode, but is flaky during
  very short windows around BOOT / MENU_RESET transitions

### 13. MENU_RESET (0x0C) - Reset to Menu
**Purpose:** Exit the running game and reload the menu ROM

**Inputs:** None

**Outputs:**
- **Response:** Standard header, sent **before** the reset sequence begins.
  Client must read the response before the firmware becomes busy.
- **Return Code:** `SNES_CMD_RESET_TO_MENU` (internal)

**Lifecycle (important for clients):**
1. Firmware sends the response.
2. Game loop catches the return code, runs `prepare_reset()` which saves
   SRM to SD card.
3. Main loop jumps to the top of `while(1)`: disk check,
   `fpga_pgm(FPGA_BASE)` to reload the menu FPGA bitstream,
   `load_rom(MENU_FILENAME, SRAM_MENU_ADDR, 0)` to paste the menu into
   SRAM, CIC init, SNES reset sequence, then re-enters `menu_main_loop`.
4. Total window ~1-3 seconds during which `usbint_handler` is not called.
   Commands sent in this window queue in the CDC recv buffer.

**MCU does not reset.** The USB CDC endpoint stays attached; the host sees
no disconnect. Do not tear down the USB connection client-side.

**Do not use `NORESP` with this opcode.** Dropping the response leaves the
firmware's send buffers mid-state and wedges subsequent commands.

### 14. STREAM (0x0D) - Stream Real-time Data
**Purpose:** Stream real-time SNES data

**Inputs:**
- **Space:** Must be MSU (operation fails if not MSU space)
- **Offset:** Stream pointer address (offset 256-259)

**Supported Flags:**
- `STREAMBURST` (16): Burst read mode - preload 0x50000 bytes and don't follow pointers
- `64BDATA` (128): Use 64-byte data blocks instead of 512-byte
- `NORESP` (64): Skip response packet, send data immediately
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation

**Response Format:**
- Standard response header with `total_size` = 0

**Data Block Format:**
Continuous 64-byte blocks containing:
- **Normal mode:** Alternates between state data (every 8th block) and MSU buffer data
  - State data: VRAM, PPU registers, CPU registers, DMA registers from 0xF50000
  - MSU data: Real-time audio buffer following head/tail pointers
- **Burst mode:** Dumps 0x50000 bytes of state data sequentially

**Notes:**
- Stream continues until connection is broken or device reset
- In normal mode, follows MSU buffer pointers for real-time data capture
- Handles MSU buffer wraparound automatically (0x7800 → 0x800 offset)
- Remaining bytes in 64-byte blocks filled with 0xFF (NOPs)

### 15. TIME (0x0E) - Set Real-time Clock
**Purpose:** Set real-time clock

**Inputs:**
- **Command bytes 8-14:** Time structure
  - Byte 8: Seconds (0-59)
  - Byte 9: Minutes (0-59)
  - Byte 10: Hours (0-23)
  - Byte 11: Day of month (1-31)
  - Byte 12: Month (1-12)
  - Bytes 13-14: Year (U16BE)
  - Byte 15: Day of week (0-6)

**Supported Flags:**
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation
- `NORESP` (64): Skip response packet

**Response Format:**
- Standard response header with `total_size` = 0

**Notes:**
- Updates the device's real-time clock hardware
- Time format follows standard calendar conventions

### 16. RESPONSE (0x0F) - Response Indicator
**Purpose:** Response opcode (used in responses only)

**Notes:** This is not a command but the opcode used in all response packets.

## Flags

| Flag | Value | Description | Applicable Operations |
|------|-------|-------------|----------------------|
| `SKIPRESET` | 1 | Skip reset deassertion in BOOT command | BOOT only |
| `ONLYRESET` | 2 | Only reset, don't load ROM in BOOT command | BOOT only |
| `CLRX` | 4 | Clear execution cheats before operation | All operations |
| `SETX` | 8 | Execute code after operation | All operations |
| `STREAMBURST` | 16 | Burst mode for STREAM operation | STREAM only |
| `NORESP` | 64 | Don't send response packet | All operations |
| `64BDATA` | 128 | Use 64-byte data blocks instead of 512-byte | Data transfer operations |

### Flag Details

**CLRX (4):** Clears execution cheats by writing RTS opcode to SNESCMD_WRAM_CHEATS and waiting 16ms

**SETX (8):** After operation completion, executes code from SRAM starting at the specified offset. Code is copied to SNESCMD_EXE region with exit sequence appended.

**NORESP (64):** Suppresses the standard response packet. For data transfer operations, the first data block is sent immediately instead.

**64BDATA (128):** Changes data block size from 512 bytes to 64 bytes. Determined during command processing and affects all subsequent data transfers for that operation.

## Memory Spaces

| Space | Value | Description |
|-------|-------|-------------|
| `FILE` | 0 | SD card file system |
| `SNES` | 1 | SNES SRAM/memory |
| `MSU` | 2 | MSU1 audio/data |
| `CMD` | 3 | SNES command region |
| `CONFIG` | 4 | FPGA configuration registers |
| `CFG` | 5 | Device configuration settings |

## Implementation Notes

- Protocol uses interrupt-driven CDC USB communication
- Proper flow control and error handling implemented
- Supports both 512-byte and 64-byte data block sizes
- Vector operations allow efficient bulk memory access
- Real-time streaming capability for debugging/monitoring
- File operations use FAT file system on SD card
- Memory operations provide direct access to SNES hardware

## Client Implementation Pitfalls (learned the hard way)

These are gotchas discovered while building the macOS client in this repo. They
are not obvious from the protocol spec and are easy to get wrong.

### INFO response parsing
`sd2snes_get_info` must actually `receive_response` after `send_packet`. An
early version skipped the read and parsed uninitialized stack memory — the
response then sat in the pipe and corrupted the next command.

### LS — don't rely on `total_size`
Response header has `total_size = 1` (placeholder). The real entries stream in
subsequent 512-byte blocks. Loop reading blocks until a `0xFF` terminator byte
is seen. Handle type-2 continuation when a filename spans a block boundary.

### PUT — pad final block to full `block_size`
Firmware aggregates incoming bulk data per-block before writing. A short final
packet leaves it waiting in `HANDLE_LOCK` — next command times out. Always
send exactly `block_size` bytes per `send_bulk_data` call, zero-padding beyond
`file_size`. Firmware only writes the declared `file_size` bytes to disk.

### Zero-length packets (ZLPs) on bulk IN
After a bulk transfer whose length is a multiple of the endpoint max-packet
size (e.g. a 512-byte response), the device emits a ZLP. The next `ReadPipe`
returns success with 0 bytes. Retry the read (2-4 attempts) before treating
it as an error.

### MENU_RESET
- The firmware does send a response; don't use `NORESP`. Without the response
  being drained, subsequent commands see stale state.
- After the response, firmware reprograms the menu FPGA and reloads
  `m3nu.bin` / `menu.bin` from SD. This takes 1-3 seconds during which
  `usbint_handler` is not called — commands sent in that window queue in the
  CDC recv buffer. Best to pause polling for a grace period.
- The MCU does not reset. USB CDC endpoint stays up, no re-enumeration.

### Game mode vs menu mode
- In menu mode: `usbint_handler` runs from `menu_main_loop`. All file
  operations work.
- In game mode: `usbint_handler` runs from the main game loop (`main.c:424`).
  Memory/SNES-space ops (GET/VGET/PUT/VPUT on `SNES`, `MSU`, `CMD`) work.
  File-space ops (LS, GET file, PUT file, BOOT) are unreliable due to SD card
  SPI contention with SRAM bridging.
- Detect mode by polling INFO and inspecting `rom_name`:
  - Suffix matches `m3nu.bin` (Mk3 / FXPAK) or `menu.bin` (Mk2) → menu mode
  - Otherwise → game mode
- Don't poll INFO during a long transfer — the poll queues behind it.

### Pipe recovery after timeout
If a `ReadPipe` fails or returns invalid data, call `ClearPipeStall` on the
bulk IN endpoint, then drain any stale bytes with short-timeout reads before
the next command. Without this, a single transient failure cascades into
unrecoverable state.

### Opcode / flag gotchas
- Firmware opcode enum has visual gaps (blank backslash-continuation lines)
  but the values are contiguous: `MV=7`, `RESET=8`. Easy to mis-count and end
  up with a RESET that actually means MV.
- Flag values are not a simple bit sequence — see the Flags table above.
  `NORESP` is 64, not 1. `DATA64B` is 128, not 32.

## Firmware Internals (notes from reading `sd2snes/src`)

Background useful for reasoning about client behavior. Source references use
line numbers from the upstream `sd2snes` repo.

### State machine (`usbinterface.c`)
```
IDLE ─(USB cmd arrives)→ HANDLE_CMD ─(usbint_handler_cmd)→ {
    GET/VGET/LS       → HANDLE_DAT    (data streamed via IRQ until done)
    PUT/VPUT          → HANDLE_LOCK   (waits for incoming bulk data)
    STREAM            → HANDLE_STREAM
    everything else   → IDLE
}
```
- `usbint_handler_cmd` runs the whole cmd pipeline: decode, dispatch, build
  and send the header response (`usbint_send_block`, `usbinterface.c:742`),
  then spin-wait on `HANDLE_LOCK/DAT/STREAM` until data drains.
- The actual data for GET/LS/VGET is pushed by `usbint_handler_dat` called
  from the CDC IRQ when the IN endpoint is ready (`cdcuser.c:371`).

### Double-buffered send
`send_buffer[0..1]` ping-pongs. `usbint_send_block` marks the current buffer
occupied and flips the index. If both are in flight, `CDC_block_send` busy-
waits on `Endpoint_IsINReady`. The client should not rely on any ordering
guarantee beyond "header first, then data blocks".

### Who calls `usbint_handler`?
- `menu_main_loop` (`snes.c:369`): every ~20ms while in menu.
- Main game loop (`main.c:424`): every tick while a ROM is running.
- `sysinfo_loop` / `msu1.c:324`: while in sysinfo screen or MSU playback loop.
If none of those loops are active (e.g. during `load_rom`, `fpga_pgm`,
`prepare_reset`), commands queue in the CDC recv buffer but are not acted
upon. The client must expect a silent window up to ~3s on MENU_RESET.

### MENU_RESET lifecycle
1. `usbint_handler_cmd` (line 572): sets `ret = SNES_CMD_RESET_TO_MENU`,
   state goes IDLE, sends standard response header.
2. Returns up to the game loop; main.c case `SNES_CMD_RESET_TO_MENU`
   (line 466): `prepare_reset()` (saves SRM to SD), `goto snes_loop_out`.
3. Loop top of `while(1)` in main: disk check, `fpga_pgm(FPGA_BASE)`,
   `load_rom(MENU_FILENAME, SRAM_MENU_ADDR, 0)`, CIC init, SNES reset
   dance, then `menu_main_loop` runs again.
4. **MCU never resets.** USB CDC endpoint stays attached. Host does not see
   re-enumeration. No `disconnect()` / `connect()` cycle needed on the host
   side — only a grace period before sending the next command.

### BOOT lifecycle
Same shape but `SNES_CMD_GAMELOOP` instead of `RESET_TO_MENU`. Control lands
in the game loop at `main.c:421` which still calls `usbint_handler` each
iteration. File ops in that mode are unreliable because `load_rom` and
`sram_reliable` are hammering the SPI bus the SD card shares.

### FPGA / FATFS contention
SD card access goes over the same SPI bus used for SRAM bridging in game
mode. FATFS calls (`f_opendir`, `f_open`, `f_read`) from LS/GET/PUT will
serialize against ongoing `sram_readblock` / `sram_writeblock` traffic.
Expected behavior: works in menu mode, flaky to dead in game mode.

### Menu ROM filename varies by hardware
- Mk2: `/sd2snes/menu.bin` (`config-mk2`)
- Mk3 / FXPAK PRO STM32: `/sd2snes/m3nu.bin` (`config-mk3-stm32:62`)
Detecting "menu vs game" by exact path is fragile; suffix match on the two
known binaries is the pragmatic choice.

### Response structure for INFO
Extended beyond the standard header. `current_filename` lives at offset 16
and is updated by `load_rom` before each boot — that's why it's the
canonical source of truth for "what is currently loaded on the cart."
Polling INFO and reading `current_filename` is the only supported way to
distinguish menu from game externally.

### LS output format, authoritatively
From `usbinterface.c:892`:
```c
send_buffer[send_buffer_index][bytesSent++] = (fi.fattrib & AM_DIR) ? 0 : 1;
strcpy((TCHAR*)send_buffer[send_buffer_index] + bytesSent, (TCHAR*)name);
bytesSent += strlen((TCHAR*)name) + 1;
```
Each entry is exactly `1 + strlen(name) + 1` bytes. No size, no date, no
attribute flags beyond dir/file — the firmware has `fi.fsize`, `fi.fdate`,
`fi.ftime` available in the FATFS `FILINFO` but chooses not to emit them.
Adding those requires a firmware patch (new `LS_EX` opcode is the
least-breaking approach).

### CDC send buffer size
`USB_CDC_BUFINSIZE` defines the max packet size (typically 64 bytes on
LPC1754 CDC). A 512-byte response is therefore 8 packets + ZLP. Host-side
`ReadPipe` of 512 may return the 512 bytes then see the ZLP as a separate
read returning 0 — client code must tolerate this.

## Source Code References

The implementation can be found in the following files:
- `usbinterface.c` - Main protocol handler
- `usbinterface.h` - Protocol definitions and constants
- `cdcuser.c` - CDC USB communication layer
- `usb.h` - USB standard definitions
- `usbcore.c` - USB core functionality