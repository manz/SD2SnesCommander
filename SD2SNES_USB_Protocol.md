# SD2SNES USB Protocol Documentation

## Overview

The SD2SNES uses a custom USB protocol built on top of CDC (Communication Device Class). The protocol uses a packet-based interface where operations consist of command-response pairs, with optional data transfers.

## Packet Structure

### USB Command Format

| Offset | Length | Contents |
|--------|--------|----------|
| 0      | 4      | Magic: 'USBA' |
| 4      | 1      | Opcode (operation type) |
| 5      | 1      | Space (context/realm) |
| 6      | 1      | Flags (options) |
| 252    | 4      | Size (U32BE - big endian) |
| 256    | 256    | File/directory name (for file operations) |

### USB Response Format

| Offset | Length | Contents |
|--------|--------|----------|
| 0      | 4      | Magic: 'USBA' |
| 4      | 1      | Opcode = 0x0f (RESPONSE) |
| 5      | 1      | Error code |
| 252    | 4      | Response size (U32BE) |

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
- Standard response header with `total_size` = 0

**Data Block Format:**
- Raw binary data in 512-byte or 64-byte blocks (depending on `64BDATA` flag)
- Last block may be partially filled

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
- Standard response header with `total_size` = 1

**Data Block Format:**
Each data block contains multiple directory entries with this format:
- **1 byte:** Entry type
  - `0`: Directory
  - `1`: File
  - `2`: Continuation (current entry continues in next block)
  - `0xFF`: End of directory listing
- **Variable bytes:** Null-terminated filename (when type ≠ 2, 0xFF)

**Notes:**
- Prefers long filenames when available, falls back to 8.3 names (converted to lowercase)
- Handles buffer overflow with continuation entries (type=2)
- Skips volume labels
- Multiple entries may fit in one data block

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
**Purpose:** Load and boot ROM file

**Inputs:**
- **String Parameter:** ROM file path

**Supported Flags:**
- `SKIPRESET` (1): Don't release reset after loading ROM
- `ONLYRESET` (2): Only release reset, don't load ROM (use with previously loaded ROM)
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation
- `NORESP` (64): Skip response packet

**Response Format:**
- Standard response header with `total_size` = 0

**Behavior:**
- If not `ONLYRESET`: Loads ROM file, configures SRAM and FPGA, adds to recent games
- If not `SKIPRESET`: Releases SNES reset and enters game loop
- Returns `SNES_CMD_GAMELOOP` to main loop when entering game mode

**Notes:**
- ROM loading includes SRAM restoration and FPGA configuration
- File is added to recent games list for menu system

### 11. POWER_CYCLE (0x0A) - Reset Device
**Purpose:** Reset the SD2SNES device

**Inputs:** None

**Outputs:** None (device resets)

**Notes:** Calls `NVIC_SystemReset()` to reset microcontroller.

### 12. INFO (0x0B) - Get Device Information
**Purpose:** Get device information

**Inputs:** None

**Supported Flags:**
- `SETX` (8): Execute code after operation
- `CLRX` (4): Clear execution cheats before operation
- `NORESP` (64): Skip response packet

**Response Format:**
Extended response structure containing:
- **Offset 0-3:** Magic 'USBA'
- **Offset 4:** Opcode 0x0F (RESPONSE)
- **Offset 5:** Error code
- **Offset 6-7:** FPGA feature flags (U16LE)
- **Offset 8-9:** Reserved (0)
- **Offset 10-11:** System config flags (U16LE)
  - Bit 0: In-game hook enabled
  - Bit 1: Save states enabled (requires in-game hook)
- **Offset 12-15:** Reserved (0)
- **Offset 16-255:** Current ROM filename (null-terminated)
- **Offset 252-255:** Response size (0)
- **Offset 256-259:** Firmware version magic (`CONFIG_FWVER`, U32BE)
- **Offset 260-323:** Firmware version string (e.g. "v1.11.1", null-terminated)
- **Offset 324-387:** Device name (e.g. "sd2snes Mk.II", "FXPAK PRO STM32", null-terminated)

**Notes:**
- This is the only operation with an extended response format
- All other fields in 512-byte response are zeroed

### 13. MENU_RESET (0x0C) - Reset to Menu
**Purpose:** Reset to menu

**Inputs:** None

**Outputs:**
- **Response:** Status only
- **Return Code:** `SNES_CMD_RESET_TO_MENU`

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

## Source Code References

The implementation can be found in the following files:
- `usbinterface.c` - Main protocol handler
- `usbinterface.h` - Protocol definitions and constants
- `cdcuser.c` - CDC USB communication layer
- `usb.h` - USB standard definitions
- `usbcore.c` - USB core functionality