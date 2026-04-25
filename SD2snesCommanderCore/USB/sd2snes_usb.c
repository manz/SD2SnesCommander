#include "sd2snes_usb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

// Global state. The device interfaces are protected by g_lock; g_is_connected
// is atomic so sd2snes_is_connected() can be polled without contending with
// long-running transfers.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static IOUSBDeviceInterface320 **g_device_interface = NULL;
static IOUSBInterfaceInterface300 **g_interface_interface = NULL;
static atomic_bool g_is_connected = false;

// RAII-style lock guard via clang/gcc cleanup attribute. Tag a public entry
// point body with WITH_LOCK; to serialize access to the device until the
// function returns from any path.
static inline void sd2snes_unlock_guard(pthread_mutex_t **m) {
    pthread_mutex_unlock(*m);
}
#define WITH_LOCK                                                              \
    pthread_mutex_lock(&g_lock);                                               \
    __attribute__((cleanup(sd2snes_unlock_guard)))                             \
        pthread_mutex_t *_sd2snes_lock_guard = &g_lock;                        \
    (void)_sd2snes_lock_guard

// Internal function declarations
static sd2snes_error_t find_device(io_service_t *device_service);
static sd2snes_error_t open_device(io_service_t device_service);
static sd2snes_error_t open_interface(void);
static sd2snes_error_t send_packet(sd2snes_opcode_t opcode, sd2snes_space_t space,
                                   sd2snes_flags_t flags, const char* parameter,
                                   const uint8_t* data, uint32_t data_size);
static sd2snes_error_t receive_response(uint8_t* response_buffer, uint32_t* response_size);
static sd2snes_error_t send_bulk_data(const uint8_t* data, uint32_t size);
static sd2snes_error_t receive_bulk_data(uint8_t* buffer, uint32_t size, uint32_t* bytes_received);

// Device Management Functions

sd2snes_error_t sd2snes_connect(void) {
    WITH_LOCK;
    sd2snes_error_t result;
    io_service_t device_service;

    printf("[SD2SNES] Starting connection process...\n");

    if (g_is_connected) {
        printf("[SD2SNES] Already connected, returning success\n");
        return SD2SNES_SUCCESS;
    }

    printf("[SD2SNES] Looking for SD2SNES device (VID: 0x%04x, PID: 0x%04x)\n",
           SD2SNES_VENDOR_ID, SD2SNES_PRODUCT_ID);

    // Find SD2SNES device
    result = find_device(&device_service);
    if (result != SD2SNES_SUCCESS) {
        printf("[SD2SNES] Device not found, error: %d\n", result);
        return result;
    }
    printf("[SD2SNES] Device found successfully\n");

    // Open device
    printf("[SD2SNES] Opening device...\n");
    result = open_device(device_service);
    if (result != SD2SNES_SUCCESS) {
        printf("[SD2SNES] Failed to open device, error: %d\n", result);
        IOObjectRelease(device_service);
        return result;
    }
    printf("[SD2SNES] Device opened successfully\n");

    // Open interface
    printf("[SD2SNES] Opening interface...\n");
    result = open_interface();
    if (result != SD2SNES_SUCCESS) {
        printf("[SD2SNES] Failed to open interface, error: %d\n", result);
        sd2snes_disconnect();
        IOObjectRelease(device_service);
        return result;
    }
    printf("[SD2SNES] Interface opened successfully\n");

    IOObjectRelease(device_service);
    g_is_connected = true;
    printf("[SD2SNES] Connection completed successfully!\n");
    return SD2SNES_SUCCESS;
}

void sd2snes_disconnect(void) {
    WITH_LOCK;
    if (g_interface_interface) {
        (*g_interface_interface)->USBInterfaceClose(g_interface_interface);
        (*g_interface_interface)->Release(g_interface_interface);
        g_interface_interface = NULL;
    }

    if (g_device_interface) {
        (*g_device_interface)->USBDeviceClose(g_device_interface);
        (*g_device_interface)->Release(g_device_interface);
        g_device_interface = NULL;
    }

    g_is_connected = false;
}

bool sd2snes_is_connected(void) {
    // Lock-free atomic read so this stays cheap during long transfers.
    return atomic_load(&g_is_connected);
}

// Function to clear a USB pipe by reading all available data
sd2snes_error_t clear_usb_pipe(IOUSBInterfaceInterface300 **interface_interface, UInt8 pipeRef) {
    kern_return_t result;
    UInt32 bytes_read = 0;
    UInt32 buffer_size = USB_BLOCK_SIZE;
    uint8_t buffer[buffer_size];

    // Read repeatedly until there is no more data or an error occurs
    do {
        // Use ReadPipe with a timeout to avoid blocking indefinitely
        // Note: The timeout is set to a short duration (e.g., 10 ms)
        // to check for data without waiting for long periods.
        result = (*interface_interface)->ReadPipeTO(interface_interface, pipeRef, buffer, &buffer_size, 10, 10);
        
        if (result == kIOReturnSuccess) {
            bytes_read += buffer_size;
            printf("Cleared %u bytes from pipe %u\n", buffer_size, pipeRef);
            // Reset buffer_size for the next read
            buffer_size = USB_BLOCK_SIZE;
        } else if (result == kIOUSBTransactionTimeout) {
            // This is the expected result when the pipe is empty
            printf("Pipe %u is empty.\n", pipeRef);
            return SD2SNES_SUCCESS;
        } else {
            // A genuine error occurred
            printf("Error clearing pipe %u: 0x%08x\n", pipeRef, result);
            return SD2SNES_ERROR_TRANSFER_FAILED;
        }
    } while (result == kIOReturnSuccess); // Continue as long as we successfully read data

    return SD2SNES_SUCCESS;
}

// Reset pipe to a known-empty state after a failed transfer.
// Clears any USB halt/stall, then drains stale data.
// If the device looks gone, mark us disconnected so callers stop pretending.
static void recover_pipe(IOUSBInterfaceInterface300 **interface_interface, UInt8 pipeRef) {
    if (!interface_interface || !*interface_interface) return;
    kern_return_t result = (*interface_interface)->ClearPipeStall(interface_interface, pipeRef);
    if (result != kIOReturnSuccess) {
        printf("[SD2SNES] recover_pipe ClearPipeStall pipe %u: 0x%08x\n", pipeRef, result);
        if (result == kIOReturnNoDevice ||
            result == kIOReturnNotResponding ||
            result == kIOReturnNotAttached ||
            result == kIOReturnAborted) {
            atomic_store(&g_is_connected, false);
            return;
        }
    } else {
        printf("[SD2SNES] recover_pipe pipe %u cleared\n", pipeRef);
    }
    clear_usb_pipe(interface_interface, pipeRef);
}

// File Operations

sd2snes_error_t sd2snes_list_files(const char* path,
                                   sd2snes_file_info_t* files,
                                   size_t max_files,
                                   size_t* file_count) {
    WITH_LOCK;
    if (!g_is_connected || !files || !file_count) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send LS command
    result = send_packet(SD2SNES_OP_LS, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        path ? path : "", NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Receive response header (total_size is a placeholder for LS — ignore)
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    *file_count = 0;

    // Pending partial name from previous block (type 2 = continuation)
    char partial_name[512] = {0};
    size_t partial_len = 0;
    uint8_t partial_type = 0;
    int has_partial = 0;

    // Stream entry blocks until 0xFF terminator. Always drain to the
    // terminator so the next command sees a clean pipe; if the caller's
    // buffer fills mid-stream, keep parsing but stop writing entries and
    // surface BUFFER_OVERFLOW once done.
    int done = 0;
    int overflow = 0;
    while (!done) {
        uint8_t block[USB_BLOCK_SIZE];
        uint32_t bytes_received = 0;
        result = receive_bulk_data(block, USB_BLOCK_SIZE, &bytes_received);
        if (result != SD2SNES_SUCCESS) {
            return result;
        }

        uint32_t offset = 0;
        while (offset < bytes_received) {
            uint8_t type = block[offset];
            if (type == 0xFF) { done = 1; break; }

            offset += 1;

            uint32_t name_end = offset;
            while (name_end < bytes_received && block[name_end] != 0) {
                name_end++;
            }

            uint32_t name_length = name_end - offset;
            int name_complete = (name_end < bytes_received); // null terminator present

            if (type == 2) {
                // Continuation: append to partial, wait for next block
                if (partial_len + name_length < sizeof(partial_name)) {
                    memcpy(partial_name + partial_len, &block[offset], name_length);
                    partial_len += name_length;
                }
                if (name_complete) {
                    // Continuation ended this block — finalize
                    partial_name[partial_len] = '\0';
                    if (has_partial && *file_count < max_files) {
                        size_t copy_len = partial_len;
                        if (copy_len >= sizeof(files[*file_count].name)) {
                            copy_len = sizeof(files[*file_count].name) - 1;
                        }
                        memcpy(files[*file_count].name, partial_name, copy_len);
                        files[*file_count].name[copy_len] = '\0';
                        files[*file_count].size = 0;
                        files[*file_count].is_directory = (partial_type == 0);
                        (*file_count)++;
                    } else if (has_partial) {
                        overflow = 1;
                    }
                    partial_len = 0;
                    has_partial = 0;
                    offset = name_end + 1;
                    continue;
                } else {
                    // Wait for next block
                    break;
                }
            }

            // type 0 (dir) or 1 (file)
            if (!name_complete) {
                // Name spans block boundary without type-2 marker — treat as partial
                if (partial_len + name_length < sizeof(partial_name)) {
                    memcpy(partial_name, &block[offset], name_length);
                    partial_len = name_length;
                    partial_type = type;
                    has_partial = 1;
                }
                break;
            }

            if (name_length > 0) {
                if (*file_count < max_files) {
                    size_t copy_len = name_length;
                    if (copy_len >= sizeof(files[*file_count].name)) {
                        copy_len = sizeof(files[*file_count].name) - 1;
                    }
                    memcpy(files[*file_count].name, &block[offset], copy_len);
                    files[*file_count].name[copy_len] = '\0';
                    files[*file_count].size = 0;
                    files[*file_count].is_directory = (type == 0);
                    (*file_count)++;
                } else {
                    overflow = 1;
                }
            }

            offset = name_end + 1;
        }
    }

    printf("[SD2SNES] C level complete: parsed %zu files total%s\n",
           *file_count, overflow ? " (buffer overflow)" : "");
    return overflow ? SD2SNES_ERROR_BUFFER_OVERFLOW : SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_upload_file(const char* local_path,
                                    const char* remote_path,
                                    sd2snes_progress_callback_t progress_callback,
                                    void* userdata) {
    WITH_LOCK;
    if (!g_is_connected || !local_path || !remote_path) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    // Open local file
    FILE* file = fopen(local_path, "rb");
    if (!file) {
        return SD2SNES_ERROR_FILE_ERROR;
    }

    // Get file size
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);

    if (file_size <= 0) {
        fclose(file);
        return SD2SNES_ERROR_FILE_ERROR;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send PUT command
    result = send_packet(SD2SNES_OP_PUT, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        remote_path, NULL, file_size);
    if (result != SD2SNES_SUCCESS) {
        fclose(file);
        return result;
    }

    // Receive response
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        fclose(file);
        return result;
    }

    // Check for error in response
    if (response_buffer[5] != 0) {
        fclose(file);
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    // Send file data in fixed USB_BLOCK_SIZE chunks. Firmware aggregates per
    // block before writing — short final packet would leave it waiting.
    uint8_t buffer[USB_BLOCK_SIZE];
    long bytes_sent = 0;

    while (bytes_sent < file_size) {
        memset(buffer, 0, USB_BLOCK_SIZE);
        size_t chunk_size = fread(buffer, 1, USB_BLOCK_SIZE, file);
        if (chunk_size == 0) {
            break;
        }

        // Always send a full block — firmware only writes file_size bytes anyway
        result = send_bulk_data(buffer, USB_BLOCK_SIZE);
        if (result != SD2SNES_SUCCESS) {
            fclose(file);
            return result;
        }

        bytes_sent += chunk_size;

        if (progress_callback) {
            double progress = (double)bytes_sent / (double)file_size;
            progress_callback(progress, userdata);
        }
    }
/*
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        fclose(file);
        return result;
    }
    
    // Check the error code in the final response
    if (response_buffer[5] != 0) {
        fclose(file);
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }
    */
    
    fclose(file);
    
    clear_usb_pipe(g_interface_interface, 2);

    return SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_download_file(const char* remote_path,
                                      const char* local_path,
                                      sd2snes_progress_callback_t progress_callback,
                                      void* userdata) {
    WITH_LOCK;
    if (!g_is_connected || !remote_path || !local_path) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send GET command
    result = send_packet(SD2SNES_OP_GET, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        remote_path, NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Receive response
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Check for error in response
    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    // Get file size from response header (U32BE at offset 252-255)
    uint32_t file_size = ((uint32_t)response_buffer[252] << 24) |
                         ((uint32_t)response_buffer[253] << 16) |
                         ((uint32_t)response_buffer[254] <<  8) |
                         ((uint32_t)response_buffer[255]);

    // Open local file for writing
    FILE* file = fopen(local_path, "wb");
    if (!file) {
        return SD2SNES_ERROR_FILE_ERROR;
    }

    // Receive file data
    uint8_t buffer[USB_BLOCK_SIZE];
    uint32_t bytes_received_total = 0;

    while (bytes_received_total < file_size) {
        uint32_t bytes_to_receive = (file_size - bytes_received_total < USB_BLOCK_SIZE) ?
                                   (file_size - bytes_received_total) : USB_BLOCK_SIZE;
        uint32_t bytes_received;

        result = receive_bulk_data(buffer, bytes_to_receive, &bytes_received);
        if (result != SD2SNES_SUCCESS) {
            fclose(file);
            return result;
        }

        if (fwrite(buffer, 1, bytes_received, file) != bytes_received) {
            fclose(file);
            return SD2SNES_ERROR_FILE_ERROR;
        }

        bytes_received_total += bytes_received;

        // Call progress callback if provided
        if (progress_callback) {
            double progress = (double)bytes_received_total / (double)file_size;
            progress_callback(progress, userdata);
        }
    }

    fclose(file);
    
    clear_usb_pipe(g_interface_interface, 2);

    
    return SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_delete_file(const char* remote_path) {
    WITH_LOCK;
    if (!g_is_connected || !remote_path) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send RM command
    result = send_packet(SD2SNES_OP_RM, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        remote_path, NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Receive response
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Check for error in response
    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    clear_usb_pipe(g_interface_interface, 2);

    
    return SD2SNES_SUCCESS;
}

// Device Control Functions

sd2snes_error_t sd2snes_boot_rom(const char* rom_path) {
    WITH_LOCK;
    if (!g_is_connected || !rom_path) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send BOOT command
    result = send_packet(SD2SNES_OP_BOOT, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        rom_path, NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Receive response
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Check for error in response
    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }
    
    clear_usb_pipe(g_interface_interface, 2);


    return SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_reset_device(void) {
    WITH_LOCK;
    if (!g_is_connected) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    // Send RESET command
    result = send_packet(SD2SNES_OP_RESET, SD2SNES_SPACE_SNES, SD2SNES_FLAG_NONE,
                        "", NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }
/*
    // Receive response
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Check for error in response
    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }
*/
    clear_usb_pipe(g_interface_interface, 2);

    return SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_menu_reset(void) {
    WITH_LOCK;
    if (!g_is_connected) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;

    result = send_packet(SD2SNES_OP_MENU_RESET, SD2SNES_SPACE_SNES, SD2SNES_FLAG_NONE,
                        "", NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Best-effort read the response — firmware sends it before actually
    // reloading the menu FPGA. Tolerate timeout since the reload may
    // start before the packet drains.
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        printf("[SD2SNES] menu_reset response missed (%d) — proceeding\n", result);
        return SD2SNES_SUCCESS;
    }

    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    return SD2SNES_SUCCESS;
}

sd2snes_error_t sd2snes_get_info(sd2snes_info_t *info) {
    WITH_LOCK;
    if (!g_is_connected) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }
    
    sd2snes_error_t result;
    uint8_t response_buffer[USB_BLOCK_SIZE];
    uint32_t response_size;
    
    // Send INFO command
    result = send_packet(SD2SNES_OP_INFO, SD2SNES_SPACE_FILE, SD2SNES_FLAG_NONE,
                        "", NULL, 0);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    // Read response block (512 bytes)
    result = receive_response(response_buffer, &response_size);
    if (result != SD2SNES_SUCCESS) {
        return result;
    }

    if (response_buffer[5] != 0) {
        return SD2SNES_ERROR_PROTOCOL_ERROR;
    }

    if (info) {
        info->firmware_version      = (uint16_t)(response_buffer[6]  | (response_buffer[7]  << 8));
        info->current_features      = (uint16_t)(response_buffer[8]  | (response_buffer[9]  << 8));
        info->current_configuration = (uint16_t)(response_buffer[10] | (response_buffer[11] << 8));

        strncpy(info->rom_name, (char*)response_buffer + 16, sizeof(info->rom_name) - 1);
        info->rom_name[sizeof(info->rom_name) - 1] = '\0';

        info->firmware_version2 = (uint32_t)(response_buffer[256] << 24 |
                                             response_buffer[257] << 16 |
                                             response_buffer[258] <<  8 |
                                             response_buffer[259]);

        strncpy(info->firmware_string, (char*)response_buffer + 260, sizeof(info->firmware_string) - 1);
        info->firmware_string[sizeof(info->firmware_string) - 1] = '\0';

        strncpy(info->device_name, (char*)response_buffer + 324, sizeof(info->device_name) - 1);
        info->device_name[sizeof(info->device_name) - 1] = '\0';
    }

    return SD2SNES_SUCCESS;
}


// Utility Functions

const char* sd2snes_error_string(sd2snes_error_t error) {
    switch (error) {
        case SD2SNES_SUCCESS:
            return "Success";
        case SD2SNES_ERROR_DEVICE_NOT_FOUND:
            return "Device not found";
        case SD2SNES_ERROR_CONNECTION_FAILED:
            return "Connection failed";
        case SD2SNES_ERROR_TRANSFER_FAILED:
            return "Transfer failed";
        case SD2SNES_ERROR_PROTOCOL_ERROR:
            return "Protocol error";
        case SD2SNES_ERROR_INVALID_RESPONSE:
            return "Invalid response";
        case SD2SNES_ERROR_FILE_ERROR:
            return "File error";
        case SD2SNES_ERROR_INVALID_PARAMETER:
            return "Invalid parameter";
        case SD2SNES_ERROR_BUFFER_OVERFLOW:
            return "Result buffer too small";
        default:
            return "Unknown error";
    }
}

// Internal Implementation Functions

static sd2snes_error_t find_device(io_service_t *device_service) {
    // Use IOUSBDevice explicitly (libusb approach for macOS compatibility)
    // This works better than IOUSBHostDevice which "misses some devices"
    static const char *darwin_device_class = "IOUSBDevice";

    printf("[SD2SNES] Creating matching dictionary for class: %s\n", darwin_device_class);
    CFMutableDictionaryRef matching_dict = IOServiceMatching(darwin_device_class);
    if (!matching_dict) {
        printf("[SD2SNES] ERROR: Failed to create matching dictionary\n");
        return SD2SNES_ERROR_DEVICE_NOT_FOUND;
    }
    printf("[SD2SNES] Matching dictionary created\n");

    // Set vendor and product ID (using IOUSBDevice property names)
    CFNumberRef vendor_id = CFNumberCreate(kCFAllocatorDefault, kCFNumberShortType, &(UInt16){SD2SNES_VENDOR_ID});
    CFNumberRef product_id = CFNumberCreate(kCFAllocatorDefault, kCFNumberShortType, &(UInt16){SD2SNES_PRODUCT_ID});

    printf("[SD2SNES] Setting matching criteria: VID=0x%04x, PID=0x%04x\n",
           SD2SNES_VENDOR_ID, SD2SNES_PRODUCT_ID);
    CFDictionarySetValue(matching_dict, CFSTR(kUSBVendorID), vendor_id);
    CFDictionarySetValue(matching_dict, CFSTR(kUSBProductID), product_id);

    CFRelease(vendor_id);
    CFRelease(product_id);

    // Find matching services
    io_iterator_t iterator;
    printf("[SD2SNES] Searching for matching USB devices...\n");
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matching_dict, &iterator);

    if (result != KERN_SUCCESS) {
        printf("[SD2SNES] ERROR: IOServiceGetMatchingServices failed with code: 0x%08x\n", result);
        return SD2SNES_ERROR_DEVICE_NOT_FOUND;
    }
    printf("[SD2SNES] Device search completed, checking results...\n");

    // Get first matching device
    *device_service = IOIteratorNext(iterator);

    if (*device_service == 0) {
        printf("[SD2SNES] ERROR: No matching devices found\n");
        printf("[SD2SNES] Make sure SD2SNES is connected and powered on\n");
        IOObjectRelease(iterator);
        return SD2SNES_ERROR_DEVICE_NOT_FOUND;
    }

    printf("[SD2SNES] Found matching device (service: 0x%08x)\n", *device_service);
    IOObjectRelease(iterator);
    return SD2SNES_SUCCESS;
}

static sd2snes_error_t open_device(io_service_t device_service) {
    IOCFPlugInInterface **plugin_interface = NULL;
    SInt32 score;

    // Try to create plugin interface for IOUSBDevice
    printf("[SD2SNES] Creating plugin interface for device service 0x%08x\n", device_service);
    kern_return_t result = IOCreatePlugInInterfaceForService(
        device_service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin_interface,
        &score);

    if (result != KERN_SUCCESS || !plugin_interface) {
        printf("[SD2SNES] ERROR: Failed to create plugin interface, result: 0x%08x, interface: %p\n",
               result, plugin_interface);
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Plugin interface created successfully (score: %d)\n", score);

    // Get device interface
    printf("[SD2SNES] Querying for IOUSBDeviceInterface320...\n");
    HRESULT query_result = (*plugin_interface)->QueryInterface(
        plugin_interface,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320),
        (LPVOID*)&g_device_interface);

    (*plugin_interface)->Release(plugin_interface);

    if (query_result != S_OK) {
        printf("[SD2SNES] ERROR: Failed to query device interface, HRESULT: 0x%08lx\n", (long)query_result);
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Device interface obtained successfully\n");

    // Open the device
    printf("[SD2SNES] Opening USB device interface...\n");
    result = (*g_device_interface)->USBDeviceOpen(g_device_interface);
    if (result != kIOReturnSuccess) {
        printf("[SD2SNES] Initial open failed (0x%08x), attempting to seize device...\n", result);

        // Try to seize the device from another driver
        result = (*g_device_interface)->USBDeviceOpenSeize(g_device_interface);
        if (result != kIOReturnSuccess) {
            printf("[SD2SNES] ERROR: Failed to seize USB device, IOReturn: 0x%08x\n", result);
            (*g_device_interface)->Release(g_device_interface);
            g_device_interface = NULL;
            return SD2SNES_ERROR_CONNECTION_FAILED;
        }
        printf("[SD2SNES] Device seized successfully from existing driver\n");
    } else {
        printf("[SD2SNES] USB device opened successfully (no seizure required)\n");
    }
    return SD2SNES_SUCCESS;
}

static sd2snes_error_t open_interface(void) {
    printf("[SD2SNES] Opening USB interface...\n");
    if (!g_device_interface) {
        printf("[SD2SNES] ERROR: Device interface is NULL\n");
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }

    // Create interface iterator for CDC Data Interface
    printf("[SD2SNES] Creating interface iterator...\n");
    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass = 0x0A;          // CDC Data Interface Class
    request.bInterfaceSubClass = 0x00;       // No subclass for data interface
    request.bInterfaceProtocol = 0x00;       // No protocol specified
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    printf("[SD2SNES] Interface search criteria: class=0x0A (CDC Data), subclass=0x00, protocol=0x00, setting=any\n");

    io_iterator_t iterator;
    kern_return_t result = (*g_device_interface)->CreateInterfaceIterator(g_device_interface, &request, &iterator);

    if (result != kIOReturnSuccess) {
        printf("[SD2SNES] ERROR: Failed to create interface iterator, IOReturn: 0x%08x\n", result);
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Interface iterator created successfully\n");

    // Get first interface (CDC data interface)
    printf("[SD2SNES] Getting first interface from iterator...\n");
    io_service_t interface_service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (interface_service == 0) {
        printf("[SD2SNES] ERROR: No interface found\n");
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Interface service found: 0x%08x\n", interface_service);

    // Create plugin interface for the interface
    printf("[SD2SNES] Creating plugin interface for USB interface...\n");
    IOCFPlugInInterface **plugin_interface = NULL;
    SInt32 score;

    result = IOCreatePlugInInterfaceForService(
        interface_service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin_interface,
        &score);

    IOObjectRelease(interface_service);

    if (result != KERN_SUCCESS || !plugin_interface) {
        printf("[SD2SNES] ERROR: Failed to create interface plugin, result: 0x%08x, interface: %p\n",
               result, plugin_interface);
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Interface plugin created successfully (score: %d)\n", score);

    // Get interface interface
    printf("[SD2SNES] Querying for IOUSBInterfaceInterface300...\n");
    HRESULT query_result = (*plugin_interface)->QueryInterface(
        plugin_interface,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
        (LPVOID*)&g_interface_interface);

    (*plugin_interface)->Release(plugin_interface);

    if (query_result != S_OK) {
        printf("[SD2SNES] ERROR: Failed to query interface interface, HRESULT: 0x%08lx\n", (long)query_result);
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] Interface interface obtained successfully\n");

    // Open the interface
    printf("[SD2SNES] Opening USB interface...\n");
    result = (*g_interface_interface)->USBInterfaceOpen(g_interface_interface);
    if (result != kIOReturnSuccess) {
        printf("[SD2SNES] Initial interface open failed (0x%08x), attempting to seize interface...\n", result);

        // Try to seize the interface from another driver
        result = (*g_interface_interface)->USBInterfaceOpenSeize(g_interface_interface);
        if (result != kIOReturnSuccess) {
            printf("[SD2SNES] ERROR: Failed to seize USB interface, IOReturn: 0x%08x\n", result);
            (*g_interface_interface)->Release(g_interface_interface);
            g_interface_interface = NULL;
            return SD2SNES_ERROR_CONNECTION_FAILED;
        }
        printf("[SD2SNES] Interface seized successfully from existing driver\n");
    } else {
        printf("[SD2SNES] USB interface opened successfully (no seizure required)\n");
    }
    return SD2SNES_SUCCESS;
}

static sd2snes_error_t send_packet(sd2snes_opcode_t opcode, sd2snes_space_t space,
                                   sd2snes_flags_t flags, const char* parameter,
                                   const uint8_t* data, uint32_t data_size) {
    if (!g_interface_interface) {
        return SD2SNES_ERROR_CONNECTION_FAILED;
    }
    printf("[SD2SNES] sending packed for opcode %d space %d.\n", opcode, space);
    // Create USB packet
    uint8_t packet[USB_BLOCK_SIZE];
    memset(packet, 0, USB_BLOCK_SIZE);

    // Magic header "USBA"
    packet[0] = 'U';
    packet[1] = 'S';
    packet[2] = 'B';
    packet[3] = 'A';

    // Command fields
    packet[4] = (uint8_t)opcode;
    packet[5] = (uint8_t)space;
    packet[6] = (uint8_t)flags;

    // Size field (little-endian at offset 252-255)
    packet[252] = (data_size >> 24) & 0xFF;
    packet[253] = (data_size >> 16) & 0xFF;
    packet[254] = (data_size >> 8) & 0xFF;
    packet[255] = data_size & 0xFF;

    // Parameter string at offset 256 (but our packet is only 512 bytes)
    if (parameter && strlen(parameter) > 0) {
        size_t param_len = strlen(parameter);
        if (param_len > 255) param_len = 255;  // Limit to fit in remaining space
        memcpy(&packet[256], parameter, param_len);
    }

    // Send the packet
    kern_return_t result = (*g_interface_interface)->WritePipe(g_interface_interface, 1, packet, USB_BLOCK_SIZE);
    if (result != kIOReturnSuccess) {
        return SD2SNES_ERROR_TRANSFER_FAILED;
    }

    return SD2SNES_SUCCESS;
}

static sd2snes_error_t receive_response(uint8_t* response_buffer, uint32_t* response_size) {
    if (!g_interface_interface || !response_buffer || !response_size) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    // Receive response header. Skip ZLPs (zero-length packets sent by device
    // after multiple-of-max-packet bulk transfers).
    UInt32 size = 0;
    int attempts = 0;
    kern_return_t result = kIOReturnSuccess;
    do {
        size = USB_BLOCK_SIZE;
        result = (*g_interface_interface)->ReadPipeTO(
            g_interface_interface, 2, response_buffer, &size, 5000, 5000);

        if (result != kIOReturnSuccess) {
            printf("[SD2SNES] receive_response ReadPipeTO failed: 0x%08x\n", result);
            recover_pipe(g_interface_interface, 2);
            return SD2SNES_ERROR_TRANSFER_FAILED;
        }
        attempts++;
    } while (size == 0 && attempts < 4);

    printf("[SD2SNES] receive_response: read %u bytes (attempts=%d), first 8: %02x %02x %02x %02x %02x %02x %02x %02x\n",
           size, attempts,
           response_buffer[0], response_buffer[1], response_buffer[2], response_buffer[3],
           response_buffer[4], response_buffer[5], response_buffer[6], response_buffer[7]);

    if (size < 8) {
        recover_pipe(g_interface_interface, 2);
        return SD2SNES_ERROR_INVALID_RESPONSE;
    }

    // Check magic header
    if (response_buffer[0] != 'U' || response_buffer[1] != 'S' ||
        response_buffer[2] != 'B' || response_buffer[3] != 'A') {
        recover_pipe(g_interface_interface, 2);
        return SD2SNES_ERROR_INVALID_RESPONSE;
    }

    // Get response size from header (U32BE at offset 252-255)
    *response_size = ((uint32_t)response_buffer[252] << 24) |
                     ((uint32_t)response_buffer[253] << 16) |
                     ((uint32_t)response_buffer[254] <<  8) |
                     ((uint32_t)response_buffer[255]);

    return SD2SNES_SUCCESS;
}

static sd2snes_error_t send_bulk_data(const uint8_t* data, uint32_t size) {
    if (!g_interface_interface || !data) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    kern_return_t result = (*g_interface_interface)->WritePipe(g_interface_interface, 1, (void*)data, size);
    if (result != kIOReturnSuccess) {
        return SD2SNES_ERROR_TRANSFER_FAILED;
    }

    return SD2SNES_SUCCESS;
}

static sd2snes_error_t receive_bulk_data(uint8_t* buffer, uint32_t size, uint32_t* bytes_received) {
    if (!g_interface_interface || !buffer || !bytes_received) {
        return SD2SNES_ERROR_INVALID_PARAMETER;
    }

    UInt32 actual_size = 0;
    int attempts = 0;
    kern_return_t result = kIOReturnSuccess;
    do {
        actual_size = size;
        result = (*g_interface_interface)->ReadPipeTO(
            g_interface_interface, 2, buffer, &actual_size, 5000, 10000);
        if (result != kIOReturnSuccess) {
            printf("[SD2SNES] receive_bulk_data ReadPipeTO failed: 0x%08x\n", result);
            recover_pipe(g_interface_interface, 2);
            return SD2SNES_ERROR_TRANSFER_FAILED;
        }
        attempts++;
    } while (actual_size == 0 && attempts < 4);

    *bytes_received = actual_size;
    return SD2SNES_SUCCESS;
}
