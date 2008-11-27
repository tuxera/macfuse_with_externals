/*
 * Copyright (C) 2006-2008 Google. All Rights Reserved.
 * Amit Singh <singh@>
 */

#ifndef _FUSE_MOUNT_H_
#define _FUSE_MOUNT_H_

#include <sys/param.h>
#include <sys/types.h>
#include <sys/stat.h>
#ifndef KERNEL
#include <unistd.h>
#endif

#include <fuse_param.h>
#include <fuse_version.h>

/*
 * Shared between the kernel and user spaces. This is 64-bit invariant.
 */
struct fuse_mount_args {
    char     mntpath[MAXPATHLEN]; // path to the mount point
    char     fsname[MAXPATHLEN];  // file system description string
    char     fstypename[MFSTYPENAMELEN]; // file system type name
    char     volname[MAXPATHLEN]; // volume name
    uint64_t altflags;            // see mount-time flags below
    uint32_t blocksize;           // fictitious block size of our "storage"
    uint32_t daemon_timeout;      // timeout in seconds for upcalls to daemon
    uint32_t fsid;                // optional custom value for part of fsid[0]
    uint32_t fssubtype;           // file system sub type id (type is "fusefs")
    uint32_t init_timeout;        // timeout in seconds for daemon handshake
    uint32_t iosize;              // maximum size for reading or writing
    uint32_t random;              // random "secret" from device
    uint32_t rdev;                // dev_t for the /dev/fuseN in question
};
typedef struct fuse_mount_args fuse_mount_args;

/* file system subtype */
enum {
    FUSE_FSSUBTYPE_UNKNOWN = 0,
    FUSE_FSSUBTYPE_INVALID = -1,
};

/* File system type name. */

#define FUSE_FSTYPENAME_PREFIX MACFUSE_FS_TYPE "_"

/* Courtesy of the Finder, this is 1 less than what you think it should be. */
#define FUSE_FSTYPENAME_MAXLEN (MFSTYPENAMELEN - sizeof(MACFUSE_FS_TYPE) - 2)

/* mount-time flags */
#define FUSE_MOPT_IGNORE                 0x0000000000000000ULL
#define FUSE_MOPT_ALLOW_OTHER            0x0000000000000001ULL
#define FUSE_MOPT_ALLOW_RECURSION        0x0000000000000002ULL
#define FUSE_MOPT_ALLOW_ROOT             0x0000000000000004ULL
#define FUSE_MOPT_AUTO_XATTR             0x0000000000000008ULL
#define FUSE_MOPT_BLOCKSIZE              0x0000000000000010ULL
#define FUSE_MOPT_DAEMON_TIMEOUT         0x0000000000000020ULL
#define FUSE_MOPT_DEBUG                  0x0000000000000040ULL
#define FUSE_MOPT_DEFAULT_PERMISSIONS    0x0000000000000080ULL
#define FUSE_MOPT_DEFER_PERMISSIONS      0x0000000000000100ULL
#define FUSE_MOPT_DIRECT_IO              0x0000000000000200ULL
#define FUSE_MOPT_EXTENDED_SECURITY      0x0000000000000400ULL
#define FUSE_MOPT_FSID                   0x0000000000000800ULL
#define FUSE_MOPT_FSNAME                 0x0000000000001000ULL
#define FUSE_MOPT_FSSUBTYPE              0x0000000000002000ULL
#define FUSE_MOPT_FSTYPENAME             0x0000000000004000ULL
#define FUSE_MOPT_INIT_TIMEOUT           0x0000000000008000ULL
#define FUSE_MOPT_IOSIZE                 0x0000000000010000ULL
#define FUSE_MOPT_JAIL_SYMLINKS          0x0000000000020000ULL
#define FUSE_MOPT_KILL_ON_UNMOUNT        0x0000000000040000ULL
#define FUSE_MOPT_LOCALVOL               0x0000000000080000ULL
#define FUSE_MOPT_NEGATIVE_VNCACHE       0x0000000000100000ULL
#define FUSE_MOPT_NO_ALERTS              0x0000000000200000ULL
#define FUSE_MOPT_NO_APPLEDOUBLE         0x0000000000400000ULL
#define FUSE_MOPT_NO_APPLEXATTR          0x0000000000800000ULL
#define FUSE_MOPT_NO_ATTRCACHE           0x0000000001000000ULL
#define FUSE_MOPT_NO_BROWSE              0x0000000002000000ULL
#define FUSE_MOPT_NO_LOCALCACHES         0x0000000004000000ULL
#define FUSE_MOPT_NO_READAHEAD           0x0000000008000000ULL
#define FUSE_MOPT_NO_SYNCONCLOSE         0x0000000010000000ULL
#define FUSE_MOPT_NO_SYNCWRITES          0x0000000020000000ULL
#define FUSE_MOPT_NO_UBC                 0x0000000040000000ULL
#define FUSE_MOPT_NO_VNCACHE             0x0000000080000000ULL

/* Next 32 bits */
#define FUSE_MOPT_USE_INO                0x0000000100000000ULL
#define FUSE_MOPT_VOLNAME                0x0000000200000000ULL
#define FUSE_MOPT_PING_DISKARB           0x0000000400000000ULL
#define FUSE_MOPT_AUTO_CACHE             0x0000000800000000ULL
#define FUSE_MOPT_NATIVE_XATTR           0x0000001000000000ULL
#define FUSE_MOPT_SPARSE                 0x0000002000000000ULL

#define FUSE_MAKEDEV(x, y)              ((dev_t)(((x) << 24) | (y)))
#define FUSE_MINOR_MASK                 0x00FFFFFFUL
#define FUSE_CUSTOM_FSID_DEVICE_MAJOR   255
#define FUSE_CUSTOM_FSID_VAL1           0x55464553

/* Notifications... */

/* The object. */

#define FUSE_UNOTIFICATIONS_OBJECT MACFUSE_BUNDLE_IDENTIFIER ".unotifications"

/* The notifications themselves. */

#define FUSE_UNOTIFICATIONS_NOTIFY_INITED           \
    FUSE_UNOTIFICATIONS_OBJECT ".inited"

#define FUSE_UNOTIFICATIONS_NOTIFY_INITTIMEDOUT     \
    FUSE_UNOTIFICATIONS_OBJECT ".inittimedout"

#define FUSE_UNOTIFICATIONS_NOTIFY_MOUNTED          \
    FUSE_UNOTIFICATIONS_OBJECT ".mounted"

/* User data keys. */

#define kFUSEDevicePathKey "kFUSEDevicePath"
#define kFUSEMountPathKey  "kFUSEMountPath"

#endif /* _FUSE_MOUNT_H_ */
