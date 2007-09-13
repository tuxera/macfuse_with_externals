/*
 * Copyright (C) 2006-2007 Google. All Rights Reserved.
 * Amit Singh <singh@>
 */

#ifndef _FUSE_FILE_H_
#define _FUSE_FILE_H_

#include <sys/types.h>
#include <sys/kernel_types.h>
#include <sys/fcntl.h>
#include <sys/kauth.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/vnode.h>

typedef enum fufh_type {
    FUFH_INVALID = -1,
    FUFH_RDONLY  = 0,
    FUFH_WRONLY  = 1,
    FUFH_RDWR    = 2,
    FUFH_MAXTYPE = 3,
} fufh_type_t;

#define FUFH_VALID    0x00000001
#define FUFH_MAPPED   0x00000002
#define FUFH_STRATEGY 0x00000004

struct fuse_filehandle {
    uint64_t    fh_id;
    fufh_type_t type;
    int         fufh_flags;
    int         open_count;
    int         open_flags;
    int         fuse_open_flags;
};
typedef struct fuse_filehandle * fuse_filehandle_t;

static __inline__
fufh_type_t
fuse_filehandle_xlate_from_mmap(int fflags)
{
    if (fflags & PROT_WRITE) {
        if (fflags & (PROT_READ | PROT_EXEC)) {
            return FUFH_RDWR;
        } else {
            return FUFH_WRONLY;
        }
    } else if (fflags & (PROT_READ | PROT_EXEC)) {
        return FUFH_RDONLY;
    } else {
        IOLog("MacFUSE: mmap being attempted with no region accessibility\n");
        return FUFH_INVALID;
    }
}

static __inline__
fufh_type_t
fuse_filehandle_xlate_from_fflags(int fflags)
{
    if ((fflags & FREAD) && (fflags & FWRITE)) {
        return FUFH_RDWR;
    } else if (fflags & (FWRITE)) {
        return FUFH_WRONLY;
    } else if (fflags & (FREAD)) {
        return FUFH_RDONLY;
    } else {
        panic("MacFUSE: What kind of a flag is this (%x)?", fflags);
    }

    return FUFH_INVALID;
}

static __inline__
int
fuse_filehandle_xlate_to_oflags(fufh_type_t type)
{
    int oflags = -1;

    switch (type) {

    case FUFH_RDONLY:
        oflags = O_RDONLY;
        break;

    case FUFH_WRONLY:
        oflags = O_WRONLY;
        break;

    case FUFH_RDWR:
        oflags = O_RDWR;
        break;

    default:
        break;
    }

    return oflags;
}

/*
 * 0 return => can proceed
 */
static __inline__
int
fuse_filehandle_preflight_status(vnode_t vp, vnode_t dvp, vfs_context_t context,
                                 fufh_type_t fufh_type)
{
    vfs_context_t icontext = context;
    kauth_action_t action  = 0;
    mount_t mp = vnode_mount(vp);
    int err = 0;

    if (vfs_authopaque(mp) || !vfs_issynchronous(mp) || !vnode_isreg(vp)) {
        goto out;
    }

    if (!icontext) {
        icontext = vfs_context_current();
    }

    if (!icontext) {
        goto out;
    }

    switch (fufh_type) {
    case FUFH_RDONLY:
        action |= KAUTH_VNODE_READ_DATA;
        break;

    case FUFH_WRONLY:
        action |= KAUTH_VNODE_WRITE_DATA;
        break;

    case FUFH_RDWR:
        action |= (KAUTH_VNODE_READ_DATA | KAUTH_VNODE_WRITE_DATA);
        break;

    default: 
        err = EINVAL;
        break;
    }

    if (!err) {
        err = vnode_authorize(vp, dvp, action, icontext);
    }

out:
    return err;
}

int fuse_filehandle_get(vnode_t vp, vfs_context_t context,
                        fufh_type_t fufh_type, int mode);
int fuse_filehandle_put(vnode_t vp, vfs_context_t context,
                        fufh_type_t fufh_type, int foregrounded);

#endif /* _FUSE_FILE_H_ */
