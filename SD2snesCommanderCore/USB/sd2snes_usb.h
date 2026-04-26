#ifndef sd2snes_usb_h
#define sd2snes_usb_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// SD2SNES USB IDs (from firmware analysis)
#define SD2SNES_VENDOR_ID   0x1209
#define SD2SNES_PRODUCT_ID  0x5A22

// USB Block size (from firmware)
#define USB_BLOCK_SIZE 512

// SD2SNES Protocol Constants (from firmware)
typedef enum {
    SD2SNES_OP_GET = 0,
    SD2SNES_OP_PUT = 1,
    SD2SNES_OP_VGET = 2,
    SD2SNES_OP_VPUT = 3,
    SD2SNES_OP_LS = 4,
    SD2SNES_OP_MKDIR = 5,
    SD2SNES_OP_RM = 6,
    SD2SNES_OP_MV = 7,
    SD2SNES_OP_RESET = 8,
    SD2SNES_OP_BOOT = 9,
    SD2SNES_OP_POWER_CYCLE = 10,
    SD2SNES_OP_INFO = 11,
    SD2SNES_OP_MENU_RESET = 12,
    SD2SNES_OP_STREAM = 13,
    SD2SNES_OP_TIME = 14,
    SD2SNES_OP_RESPONSE = 15
} sd2snes_opcode_t;

typedef enum {
    SD2SNES_SPACE_FILE = 0,
    SD2SNES_SPACE_SNES = 1,
    SD2SNES_SPACE_MSU = 2,
    SD2SNES_SPACE_CONFIG = 3
} sd2snes_space_t;

typedef enum {
    SD2SNES_FLAG_NONE = 0,
    SD2SNES_FLAG_NORESP = 1,
    SD2SNES_FLAG_SKIPRESET = 2,
    SD2SNES_FLAG_ONLYRESET = 4,
    SD2SNES_FLAG_CLRX = 8,
    SD2SNES_FLAG_SETX = 16,
    SD2SNES_FLAG_DATA64B = 32,
    SD2SNES_FLAG_STREAMMODE = 64,
    SD2SNES_FLAG_SKIPMANUTIME = 128
} sd2snes_flags_t;

// Error codes
typedef enum {
    SD2SNES_SUCCESS = 0,
    SD2SNES_ERROR_DEVICE_NOT_FOUND = -1,
    SD2SNES_ERROR_CONNECTION_FAILED = -2,
    SD2SNES_ERROR_TRANSFER_FAILED = -3,
    SD2SNES_ERROR_PROTOCOL_ERROR = -4,
    SD2SNES_ERROR_INVALID_RESPONSE = -5,
    SD2SNES_ERROR_FILE_ERROR = -6,
    SD2SNES_ERROR_INVALID_PARAMETER = -7,
    SD2SNES_ERROR_BUFFER_OVERFLOW = -8
} sd2snes_error_t;

// File info structure
typedef struct {
    char name[256];
    uint32_t size;
    bool is_directory;
} sd2snes_file_info_t;

typedef struct {
    uint16_t firmware_version;
    uint16_t current_features;
    uint16_t current_configuration;
    char rom_name[256];
    uint32_t firmware_version2;
    char firmware_string[64];
    char device_name[64];

} sd2snes_info_t;

// Progress callback function type
typedef void (*sd2snes_progress_callback_t)(double progress, void* userdata);

// Device Management Functions
sd2snes_error_t sd2snes_connect(void);
void sd2snes_disconnect(void);
bool sd2snes_is_connected(void);

// File Operations
sd2snes_error_t sd2snes_list_files(const char* path,
                                   sd2snes_file_info_t* files,
                                   size_t max_files,
                                   size_t* file_count);

sd2snes_error_t sd2snes_upload_file(const char* local_path,
                                    const char* remote_path,
                                    sd2snes_progress_callback_t progress_callback,
                                    void* userdata);

#if 0
sd2snes_error_t sd2snes_move_file(const char* source_path, const char* destination);
#endif

sd2snes_error_t sd2snes_download_file(const char* remote_path,
                                      const char* local_path,
                                      sd2snes_progress_callback_t progress_callback,
                                      void* userdata);

sd2snes_error_t sd2snes_delete_file(const char* remote_path);

// Device Control Functions
sd2snes_error_t sd2snes_boot_rom(const char* rom_path);
sd2snes_error_t sd2snes_reset_device(void);
sd2snes_error_t sd2snes_menu_reset(void);

sd2snes_error_t sd2snes_get_info(sd2snes_info_t *info);


// Utility Functions
const char* sd2snes_error_string(sd2snes_error_t error);

// Wire format helpers. Pure functions, no IOKit, exposed for unit tests.
// Build a 512-byte command packet into `packet` (must be USB_BLOCK_SIZE long).
// `parameter` is null-terminated; pass NULL or empty string when unused.
void sd2snes_build_command_packet(uint8_t* packet,
                                  sd2snes_opcode_t opcode,
                                  sd2snes_space_t space,
                                  sd2snes_flags_t flags,
                                  const char* parameter,
                                  uint32_t data_size);

// Parse the standard response header out of a 512-byte packet. Returns
// SD2SNES_ERROR_INVALID_RESPONSE when the magic is wrong; SUCCESS otherwise.
// `out_error` receives the firmware error byte (0 = success), `out_total_size`
// the U32BE size at offset 252.
sd2snes_error_t sd2snes_parse_response_header(const uint8_t* packet,
                                              uint8_t* out_error,
                                              uint32_t* out_total_size);

#ifdef __cplusplus
}
#endif

#endif /* sd2snes_usb_h */
