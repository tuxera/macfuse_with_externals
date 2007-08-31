/*
 * Copyright (C) 2006 Google. All Rights Reserved.
 * Amit Singh <singh@>
 */

#include <sys/param.h>
#include <kern/assert.h>
#include <libkern/libkern.h>
#include <libkern/OSMalloc.h>
#include <libkern/locks.h>
#include <mach/mach_types.h>
#include <sys/dirent.h>
#include <sys/disk.h>
#include <sys/errno.h>
#include <sys/fcntl.h>
#include <sys/kernel_types.h>
#include <sys/mount.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/ubc.h>
#include <sys/unistd.h>
#include <sys/vnode.h>
#include <sys/vnode_if.h>
#include <sys/xattr.h>
#include <sys/buf.h>
#include <sys/namei.h>
#include <sys/mman.h>

#include "fuse.h"
#include "fuse_file.h"
#include "fuse_internal.h"
#include "fuse_ipc.h"
#include "fuse_locking.h"
#include "fuse_node.h"
#include "fuse_file.h"
#include "fuse_nodehash.h"
#include "fuse_sysctl.h"

/* access */

__private_extern__
int
fuse_internal_access(vnode_t                   vp,
                     int                       action,
                     vfs_context_t             context,
                     struct fuse_access_param *facp)
{
    int err = 0;
    uint32_t mask = 0;
    int dataflags;
    int vtype;
    mount_t mp;
    struct fuse_dispatcher fdi;
    struct fuse_access_in *fai;
    struct fuse_data      *data;

    fuse_trace_printf_func();

    mp = vnode_mount(vp);
    vtype = vnode_vtype(vp);

    data = fuse_get_mpdata(mp);
    dataflags = data->dataflags;

    if (dataflags & FSESS_DEFER_AUTH) {
        return 0;
    }

    if ((action & KAUTH_VNODE_GENERIC_WRITE_BITS) && vfs_isrdonly(mp)) {
        return EACCES;
    }

    /* Unless explicitly permitted, deny everyone except the fs owner. */
    if (!vnode_isvroot(vp) && !(facp->facc_flags & FACCESS_NOCHECKSPY)) {
        if (!(dataflags & FSESS_ALLOW_OTHER)) {
            int denied = fuse_match_cred(data->daemoncred,
                                         vfs_context_ucred(context));
            if (denied) {
                return EPERM;
            }
        }
        facp->facc_flags |= FACCESS_NOCHECKSPY;
    }

    if (!(facp->facc_flags & FACCESS_DO_ACCESS)) {
        return 0;
    }

    if (((vtype == VREG) && (action & KAUTH_VNODE_GENERIC_EXECUTE_BITS))) {
#if M_MACFUSE_NEED_MOUNT_ARGUMENT_FOR_THIS
        // Let the kernel handle this through open/close heuristics.
        return ENOTSUP;
#else
        // Let the kernel handle this.
        return 0;
#endif
    }

    if (fuse_get_mpdata(mp)->noimplflags & FSESS_NOIMPL(ACCESS)) {
        // Let the kernel handle this.
        return 0;
    }

    if (dataflags & FSESS_DEFAULT_PERMISSIONS) {
        // Let the kernel handle this.
        return 0;
    }

    if (vtype == VDIR) {
        if (action &
            (KAUTH_VNODE_LIST_DIRECTORY | KAUTH_VNODE_READ_EXTATTRIBUTES)) {
            mask |= R_OK;
        }
        if (action & (KAUTH_VNODE_ADD_FILE | KAUTH_VNODE_ADD_SUBDIRECTORY)) {
            mask |= W_OK;
        }
        if (action & KAUTH_VNODE_DELETE_CHILD) {
            mask |= W_OK;
        }
        if (action & KAUTH_VNODE_SEARCH) {
            mask |= X_OK;
        }
    } else {
        if (action & (KAUTH_VNODE_READ_DATA | KAUTH_VNODE_READ_EXTATTRIBUTES)) {
            mask |= R_OK;
        }
        if (action & (KAUTH_VNODE_WRITE_DATA | KAUTH_VNODE_APPEND_DATA)) {
            mask |= W_OK;
        }
        if (action & KAUTH_VNODE_EXECUTE) {
            mask |= X_OK;
        }
    }

    if (action & KAUTH_VNODE_DELETE) {
        mask |= W_OK;
    }

    if (action & (KAUTH_VNODE_WRITE_ATTRIBUTES |
                  KAUTH_VNODE_WRITE_EXTATTRIBUTES |
                  KAUTH_VNODE_WRITE_SECURITY)) {
        mask |= W_OK;
    }

    bzero(&fdi, sizeof(fdi));

    fdisp_init(&fdi, sizeof(*fai));
    fdisp_make_vp(&fdi, FUSE_ACCESS, vp, context);

    fai = fdi.indata;
    fai->mask = F_OK;
    fai->mask |= mask;

    if (!(err = fdisp_wait_answ(&fdi))) {
        fuse_ticket_drop(fdi.tick);
    }

    if (err == ENOSYS) {
        /*
         * Make sure we don't come in here again.
         */
        vfs_clearauthopaque(mp);
        fuse_get_mpdata(mp)->noimplflags |= FSESS_NOIMPL(ACCESS);
        err = 0;
    }

    if (err == ENOENT) {

        int dorevoke = 1;

        IOLog("MacFUSE: disappearing vnode %p (root=%d, type=%d, action=%x)\n",
              vp, vnode_isvroot(vp), vnode_vtype(vp), action);

        /*
         * Finder's /.Trashes/<uid> issue... avoid deadlock
         */
        if (FUSE_KL_skiprevoke(vp, action)) {
            dorevoke = 0;
            IOLog("MacFUSE: skipping revoke on vnode %p\n", vp);
        }

        fuse_internal_vnode_disappear(vp, context, dorevoke);
    }

    return err;
}

/* fsync */

__private_extern__
int
fuse_internal_fsync_callback(struct fuse_ticket *ftick, __unused uio_t uio)
{
    fuse_trace_printf_func();

    if (ftick->tk_aw_ohead.error == ENOSYS) {
        if (fticket_opcode(ftick) == FUSE_FSYNC) {
            ftick->tk_data->noimplflags |= FSESS_NOIMPL(FSYNC);
        } else if (fticket_opcode(ftick) == FUSE_FSYNCDIR) {
            ftick->tk_data->noimplflags |= FSESS_NOIMPL(FSYNCDIR);
        } else {
            IOLog("MacFUSE: unexpected opcode in sync handling\n");
        }
    }

    fuse_ticket_drop(ftick);

    return 0;
}

__private_extern__
int
fuse_internal_fsync(vnode_t                 vp,
                    vfs_context_t           context,
                    struct fuse_filehandle *fufh,
                    void                   *param)
{
    int op = FUSE_FSYNC;
    struct fuse_fsync_in *ffsi;
    struct fuse_dispatcher *fdip = param;

    fuse_trace_printf_func();

    fdip->iosize = sizeof(*ffsi);
    fdip->tick = NULL;
    if (vnode_vtype(vp) == VDIR) {
        op = FUSE_FSYNCDIR;
    }
    
    fdisp_make_vp(fdip, op, vp, context);
    ffsi = fdip->indata;
    ffsi->fh = fufh->fh_id;

    ffsi->fsync_flags = 1;
  
    fuse_insert_callback(fdip->tick, fuse_internal_fsync_callback);
    fuse_insert_message(fdip->tick);

    return 0;

}

/* ioctl */
__private_extern__
int
fuse_internal_ioctl_avfi(vnode_t vp, __unused vfs_context_t context,
                         struct fuse_avfi_ioctl *avfi)
{
    int ret = 0;

    if (!avfi) {
        return EINVAL;
    }

    if (avfi->cmd & FUSE_AVFI_MARKGONE) {

        /*
         * TBD
         */
        return EINVAL;
    }

    /* The result of this /does/ alter our return value. */
    if (avfi->cmd & FUSE_AVFI_UBC) {
        int ubc_flags = avfi->flags & (UBC_PUSHDIRTY  | UBC_PUSHALL |
                                       UBC_INVALIDATE | UBC_SYNC);
        ret = ubc_sync_range(vp, (off_t)0, ubc_getsize(vp), ubc_flags);
    }

    /* The result of this doesn't alter our return value. */
    if (avfi->cmd & FUSE_AVFI_PURGEATTRCACHE) {
        (void)fuse_invalidate_attr(vp);
    }

    /* The result of this doesn't alter our return value. */
    if (avfi->cmd & FUSE_AVFI_PURGEVNCACHE) {
        fuse_vncache_purge(vp);
    }

    return ret;
}

/* readdir */

__private_extern__
int
fuse_internal_readdir(vnode_t                 vp,
                      uio_t                   uio,
                      vfs_context_t           context,
                      struct fuse_filehandle *fufh,
                      struct fuse_iov        *cookediov)
{
    int err = 0;
    struct fuse_dispatcher fdi;
    struct fuse_read_in   *fri;
    struct fuse_data      *data;

    if (uio_resid(uio) == 0) {
        return (0);
    }

    fdisp_init(&fdi, 0);

    /* Note that we DO NOT have a UIO_SYSSPACE here (so no need for p2p I/O). */

    while (uio_resid(uio) > 0) {

        fdi.iosize = sizeof(*fri);
        fdisp_make_vp(&fdi, FUSE_READDIR, vp, context);

        fri = fdi.indata;
        fri->fh = fufh->fh_id;
        fri->offset = uio_offset(uio);
        data = fuse_get_mpdata(vnode_mount(vp));
        fri->size = min(uio_resid(uio), data->iosize); // mp->max_read

        if ((err = fdisp_wait_answ(&fdi))) {
            goto out;
        }

        if ((err = fuse_internal_readdir_processdata(vp,
                                                     uio,
                                                     fri->size,
                                                     fdi.answ,
                                                     fdi.iosize,
                                                     cookediov))) {
            break;
        }
    }

/* done: */
    fuse_ticket_drop(fdi.tick);

out:
    return ((err == -1) ? 0 : err);
}

__private_extern__
int
fuse_internal_readdir_processdata(vnode_t          vp,
                                  uio_t            uio,
                         __unused size_t           reqsize,
                                  void            *buf,
                                  size_t           bufsize,
                                  struct fuse_iov *cookediov)
{
    int err = 0;
    int cou = 0;
    int bytesavail;
    size_t freclen;

    struct dirent      *de;
    struct fuse_dirent *fudge;

    if (bufsize < FUSE_NAME_OFFSET) {
        return (-1);
    }

    for (;;) {

        if (bufsize < FUSE_NAME_OFFSET) {
            err = -1;
            break;
        }

        fudge = (struct fuse_dirent *)buf;
        freclen = FUSE_DIRENT_SIZE(fudge);

        cou++;

        if (bufsize < freclen) {
            err = ((cou == 1) ? -1 : 0);
            break;
        }

        /*
         * if (isbzero(buf, FUSE_NAME_OFFSET)) {
         *     // zero-pad incomplete buffer
         *     ...
         *     err = -1;
         *     break;
         * }
         */

        if (!fudge->namelen) {
            err = EINVAL;
            break;
        }

        if (fudge->namelen > MAXNAMLEN) {
            err = EIO;
            break;
        }

#define GENERIC_DIRSIZ(dp) \
    ((sizeof (struct dirent) - (MAXNAMLEN+1)) + (((dp)->d_namlen+1 + 3) &~ 3))

        bytesavail = GENERIC_DIRSIZ((struct pseudo_dirent *)&fudge->namelen); 

        if (bytesavail > uio_resid(uio)) {
            err = -1;
            break;
        }

        fiov_refresh(cookediov);
        fiov_adjust(cookediov, bytesavail);

        de = (struct dirent *)cookediov->base;
        de->d_fileno = fudge->ino; /* XXX cast from 64 to 32 bits */
        de->d_reclen = bytesavail;
        de->d_type = fudge->type; 
        de->d_namlen = fudge->namelen;

        /* Filter out any ._* files if the mount is configured as such. */
        if (fuse_skip_apple_special_mp(vnode_mount(vp),
                                       fudge->name, fudge->namelen)) {
            de->d_fileno = 0;
            de->d_type = DT_WHT;
        }

        memcpy((char *)cookediov->base + sizeof(struct dirent) - MAXNAMLEN - 1,
               (char *)buf + FUSE_NAME_OFFSET, fudge->namelen);
        ((char *)cookediov->base)[bytesavail] = '\0';

        err = uiomove(cookediov->base, cookediov->len, uio);
        if (err) {
            break;
        }

        buf = (char *)buf + freclen;
        bufsize -= freclen;
        uio_setoffset(uio, fudge->off);
    }

    return (err);
}

/* remove */

static int
fuse_unlink_callback(vnode_t vp, void *cargs)
{
    struct vnode_attr *vap;
    uint64_t target_nlink;

    vap = VTOVA(vp);

    target_nlink = *(uint64_t *)cargs;

    if ((vap->va_nlink == target_nlink) && (vnode_vtype(vp) == VREG)) {
        fuse_invalidate_attr(vp);
    }

    return VNODE_RETURNED;
}

#define M_MACFUSE_INVALIDATE_CACHED_VATTRS_UPON_UNLINK 1
__private_extern__
int
fuse_internal_remove(vnode_t               dvp,
                     vnode_t               vp,
                     struct componentname *cnp,
                     enum fuse_opcode      op,
                     vfs_context_t         context)
{
    struct fuse_dispatcher fdi;
    struct vnode_attr *vap = VTOVA(vp);
#if M_MACFUSE_INVALIDATE_CACHED_VATTRS_UPON_UNLINK
    int need_invalidate = 0;
    uint64_t target_nlink = 0;
#endif
    int err = 0;

    debug_printf("dvp=%p, cnp=%p, op=%d, context=%p\n", vp, cnp, op, context);

    fdisp_init(&fdi, cnp->cn_namelen + 1);
    fdisp_make_vp(&fdi, op, dvp, context);

    memcpy(fdi.indata, cnp->cn_nameptr, cnp->cn_namelen);
    ((char *)fdi.indata)[cnp->cn_namelen] = '\0';

#if M_MACFUSE_INVALIDATE_CACHED_VATTRS_UPON_UNLINK
    if (vap->va_nlink > 1) {
        need_invalidate = 1;
        target_nlink = vap->va_nlink;
    }
#endif

    if (!(err = fdisp_wait_answ(&fdi))) {
        fuse_ticket_drop(fdi.tick);
    }

    fuse_invalidate_attr(dvp);
    fuse_invalidate_attr(vp);

#if M_MACFUSE_INVALIDATE_CACHED_VATTRS_UPON_UNLINK
    if (need_invalidate && !err) {
        vnode_iterate(vnode_mount(vp), 0, fuse_unlink_callback,
                      (void *)&target_nlink);
    }
#endif

    return (err);
}

/* rename */

__private_extern__
int
fuse_internal_rename(vnode_t               fdvp,
            __unused vnode_t               fvp,
                     struct componentname *fcnp,
                     vnode_t               tdvp,
            __unused vnode_t               tvp,
                     struct componentname *tcnp,
                     vfs_context_t         context)
{
    struct fuse_dispatcher fdi;
    struct fuse_rename_in *fri;
    int err = 0;

    fdisp_init(&fdi, sizeof(*fri) + fcnp->cn_namelen + tcnp->cn_namelen + 2);
    fdisp_make_vp(&fdi, FUSE_RENAME, fdvp, context);

    fri = fdi.indata;
    fri->newdir = VTOI(tdvp);
    memcpy((char *)fdi.indata + sizeof(*fri), fcnp->cn_nameptr,
           fcnp->cn_namelen);
    ((char *)fdi.indata)[sizeof(*fri) + fcnp->cn_namelen] = '\0';
    memcpy((char *)fdi.indata + sizeof(*fri) + fcnp->cn_namelen + 1,
           tcnp->cn_nameptr, tcnp->cn_namelen);
    ((char *)fdi.indata)[sizeof(*fri) + fcnp->cn_namelen +
                         tcnp->cn_namelen + 1] = '\0';
        
    if (!(err = fdisp_wait_answ(&fdi))) {
        fuse_ticket_drop(fdi.tick);
    }

    if (err == 0) {
        fuse_invalidate_attr(fdvp);
        if (tdvp != fdvp) {
            fuse_invalidate_attr(tdvp);
        }
    }

    return (err);
}

/* revoke */

__private_extern__
int
fuse_internal_revoke(vnode_t vp, int flags, vfs_context_t context)
{
    int ret;
    struct fuse_vnode_data *fvdat = VTOFUD(vp);

    fvdat->flag |= FN_REVOKING;

    IOLog("MacFUSE: revoking vnode %p\n", vp);
    ret = vn_revoke(vp, flags, context);

    fvdat->flag &= ~FN_REVOKING;
    fvdat->flag |= FN_REVOKED;

    return ret;
}

/* strategy */

__private_extern__
int
fuse_internal_strategy(vnode_t vp, buf_t bp)
{
    int biosize;
    int err = 0;
    int chunksize;
    int mapped = FALSE;
    int mode;
    int op;
    int respsize;
    int vtype = vnode_vtype(vp);

    caddr_t  bufdat;
    int32_t  bflags = buf_flags(bp);
    off_t    left;
    off_t    offset;

    fufh_type_t             fufh_type;
    struct fuse_dispatcher  fdi;
    struct fuse_data       *data;
    struct fuse_vnode_data *fvdat = VTOFUD(vp);
    struct fuse_filehandle *fufh = NULL;

    data = fuse_get_mpdata(vnode_mount(vp));

    /*
     * XXX
     * XXX: Wait, what happened here?
     * XXX
     */
    //biosize = data->iosize;
    //biosize = data->blocksize;
    biosize = data->blocksize;

    if (!(vtype == VREG || vtype == VDIR)) {
        debug_printf("STRATEGY: unsupported vnode type\n");
        return (ENOTSUP);
    }
 
    if (bflags & B_READ) {
        mode = FREAD;
        fufh_type = FUFH_RDONLY; // FUFH_RDWR will also do
    } else {
        mode = FWRITE;
        fufh_type = FUFH_WRONLY; // FUFH_RDWR will also do
    }

    fufh = &(fvdat->fufh[fufh_type]);
    if (!(fufh->fufh_flags & FUFH_VALID)) {
        fufh_type = FUFH_RDWR;
        fufh = &(fvdat->fufh[fufh_type]);
        if (!(fufh->fufh_flags & FUFH_VALID)) {
            fufh = NULL;
        } else {
            debug_printf("strategy falling back to FUFH_RDWR ... OK\n");
        }
    }

    if (!fufh) {
        if (mode == FREAD) {
            fufh_type = FUFH_RDONLY;
        } else {
            fufh_type = FUFH_RDWR;
        }
        err = fuse_filehandle_get(vp, NULL, fufh_type, 0 /* mode */);
        if (!err) {
            fufh = &(fvdat->fufh[fufh_type]);
            fufh->fufh_flags |= FUFH_STRATEGY;
            debug_printf("STRATEGY: created *new* fufh of type %d\n",
                         fufh_type);
        }
    } else {
        FUSE_OSAddAtomic(1, (SInt32 *)&fuse_fh_reuse_count);
        debug_printf("STRATEGY: using existing fufh of type %d\n", fufh_type);
    }
    if (err) {

         /* A more typical error case. */
         if ((err == ENOTCONN) || fuse_isdeadfs(vp)) {
             buf_seterror(bp, EIO);
             buf_biodone(bp);
             return EIO;
         }

         /*
          * Thinking about this more, I don't think we should panic here.
          * But then, I don't have time to think right now.
          *
          * panic()?
          */
         IOLog("MacFUSE: failed to get fh from strategy (err=%d)\n", err);
         if (!vfs_issynchronous(vnode_mount(vp))) {
             IOLog("MacFUSE: asynchronous write failed!\n");
         }

         buf_seterror(bp, EIO);
         buf_biodone(bp);
         return EIO;
    }

    fufh = &(fvdat->fufh[fufh_type]);

#define B_INVAL         0x00040000      /* Does not contain valid info. */
#define B_ERROR         0x00080000      /* I/O error occurred. */
    if (bflags & B_INVAL) {
        debug_printf("*** WHOA: B_INVAL\n");
    } 
    if (bflags & B_ERROR) {
        debug_printf("*** WHOA: B_ERROR\n");
    }

    if (buf_count(bp) == 0) {
        debug_printf("STRATEGY: zero buf count?\n");
        return (0);
    }

    fdisp_init(&fdi, 0);

    if (mode == FREAD) {

        struct fuse_read_in *fri;

        buf_setresid(bp, buf_count(bp));
        offset = (off_t)((off_t)buf_blkno(bp) * biosize);

        if (offset >= fvdat->filesize) {
            /* Trying to read at/after EOF? */           
            if (offset != fvdat->filesize) {
                /* Trying to read after EOF? */
                buf_seterror(bp, EINVAL);
            }
            buf_biodone(bp);
            // fufh->useco--;
            return 0;
        }

        if ((offset + buf_count(bp)) > fvdat->filesize) {
            /* Trimming read */
            buf_setcount(bp, fvdat->filesize - offset);
        }

        if (buf_map(bp, &bufdat)) {
            IOLog("MacFUSE: failed to map buffer in strategy\n");
            // fufh->useco--;
            return EFAULT;
        } else {
            mapped = TRUE;
        }

        while (buf_resid(bp) > 0) {

            chunksize = min(buf_resid(bp), data->iosize);

            fdi.iosize = sizeof(*fri);

            op = FUSE_READ;
            if (vtype == VDIR) {
                op = FUSE_READDIR;
            }
            fdisp_make_vp(&fdi, op, vp, (vfs_context_t)0);
        
            fri = fdi.indata;
            fri->fh = fufh->fh_id;

            /*
             * Historical note:
             *
             * fri->offset = ((off_t)(buf_blkno(bp))) * biosize;
             *
             * This wasn't being incremented!?
             */

            fri->offset = offset;
            fri->size = chunksize;
            fdi.tick->tk_aw_type = FT_A_BUF;
            fdi.tick->tk_aw_bufdata = bufdat;
        
            if ((err = fdisp_wait_answ(&fdi))) {
                /* There was a problem with reading. */
                goto out;
            }

            respsize = fdi.tick->tk_aw_bufsize;

            if (respsize < 0) { /* Cannot really happen... */
                err = EIO;
                goto out;
            }

            buf_setresid(bp, buf_resid(bp) - respsize);
            bufdat += respsize;
            offset += respsize;

            /* Did we hit EOF before being done? */
            if ((respsize == 0) && (buf_resid(bp) > 0)) {
                 /*
                  * Historical note:
                  * If we don't get enough data, just fill the rest with zeros.
                  * In NFS context, this would mean a hole in the file.
                  */

                 /* Zero-pad the incomplete buffer. */
                 bzero(bufdat, buf_resid(bp));
                 buf_setresid(bp, 0);
                 break;
            }
        } /* while (buf_resid(bp) > 0) */
    } else {
        /* write */
        struct fuse_write_in  *fwi;
        struct fuse_write_out *fwo;
        int merr = 0;
        off_t diff;

#if M_MACFUSE_EXPERIMENTAL_JUNK
        /*
         * Wanna experiment with some panics?
         * Try doing something like:
         *
         *   err = EIO;
         *   goto out;
         *
         * Investigate later.
         */
#endif

        debug_printf("WRITE: preparing for write\n");

        if (buf_map(bp, &bufdat)) {
            IOLog("MacFUSE: failed to map buffer in strategy\n");
            // fufh->useco--;
            return EFAULT;
        } else {
            mapped = TRUE;
        }

        // Write begin

        buf_setresid(bp, buf_count(bp));
        offset = (off_t)((off_t)buf_blkno(bp) * biosize);

        // TBD: Check here for extension (writing past end)

        left = buf_count(bp);

        while (left) {

            fdi.iosize = sizeof(*fwi);
            op = FUSE_WRITE;

            fdisp_make_vp(&fdi, op, vp, (vfs_context_t)0);
            chunksize = min(left, data->iosize);

            fwi = fdi.indata;
            fwi->fh = fufh->fh_id;
            fwi->offset = offset;
            fwi->size = chunksize;

            fdi.tick->tk_ms_type = FT_M_BUF;
            fdi.tick->tk_ms_bufdata = bufdat;
            fdi.tick->tk_ms_bufsize = chunksize;

            debug_printf("WRITE: about to write at offset %lld chunksize %d\n",
                         offset, chunksize);

            if ((err = fdisp_wait_answ(&fdi))) {
                merr = 1;
                break;
            }
    
            fwo = fdi.answ;
            diff = chunksize - fwo->size;
            if (diff < 0) {
                err = EINVAL;
                break;
            }
    
            left -= fwo->size;
            bufdat += fwo->size;
            offset += fwo->size;
            buf_setresid(bp, buf_resid(bp) - fwo->size);
        }

        if (merr) {
            goto out;
        }

#if M_MACFUSE_EXPERIMENTAL_JUNK
        bufdat += buf_dirtyoff(bp);
        offset = (off_t)buf_blkno(bp) * biosize + buf_dirtyoff(bp);

        debug_printf("WRITE: dirtyoff = %d, dirtyend = %d, count = %d\n",
                     buf_dirtyoff(bp), buf_dirtyend(bp), buf_count(bp));

        while (buf_dirtyend(bp) > buf_dirtyoff(bp)) {

            debug_printf("WRITE: taking a shot\n");
            chunksize = min(buf_dirtyend(bp) - buf_dirtyoff(bp),
                            data->iosize); // get v_mount's max w 
    
            fdi.iosize = sizeof(*fwi);
            op = op ?: FUSE_WRITE;
            fdisp_make_vp(&fdi, op, vp, (vfs_context_t)0);
        
            fwi = fdi.indata;
            fwi->fh = fufh->fh_id;
            // fwi->offset = (off_t)buf_blkno(bp) * biosize + buf_dirtyoff(bp);
            fwi->offset = offset;
            fwi->size = chunksize;
            fdi.tick->tk_ms_type = FT_M_BUF;
            fdi.tick->tk_ms_bufdata = bufdat;
            fdi.tick->tk_ms_bufsize = chunksize;
            debug_printf("WRITE: about to write at offset %lld chunksize %d\n",
                   offset, chunksize);
            if ((err = fdisp_wait_answ(&fdi))) {
                IOLog("MacFUSE: daemon returned error %d in strategy\n", err);
                merr = 1;
                break;
            }
    
            fwo = fdi.answ;
            diff = chunksize - fwo->size;
            if (diff < 0) {
                err = EINVAL;
                break;
            }
    
            buf_setdirtyoff(bp, buf_dirtyoff(bp) + fwo->size);
            offset += fwo->size;
        }

        if (buf_dirtyend(bp) == buf_dirtyoff(bp)) {
            buf_setdirtyend(bp, 0);
            buf_setdirtyoff(bp, 0);
        }

        buf_setresid(bp, buf_dirtyend(bp) - buf_dirtyoff(bp));

        if (merr)
            goto out;

        fuse_invalidate_attr(vp);
#endif
    }

    if (fdi.tick)
        fuse_ticket_drop(fdi.tick);
    else
        debug_printf("no ticket on leave\n");

out:

#if M_MACFUSE_EXPERIMENTAL_JUNK
    if (fufh) {
        fufh->useco--;
        if (didnewfh) {
            debug_printf("strategy internal fufh count is %d\n", fufh->useco);
        }
    }
#endif

    if (err) {
        debug_printf("STRATEGY: there was an error %d\n", err);
        buf_seterror(bp, err);
    }

    if (mapped == TRUE) {
        buf_unmap(bp);
    }

    buf_biodone(bp);

    return (err);
}    

__private_extern__
errno_t
fuse_internal_strategy_buf(struct vnop_strategy_args *ap)
{
    int32_t   bflags;
    upl_t     bupl;
    daddr64_t blkno, lblkno;
    int       bmap_flags;
    buf_t     bp    = ap->a_bp;
    vnode_t   vp    = buf_vnode(bp);
    int       vtype = vnode_vtype(vp);

    struct fuse_data *data;

    if (!vp || vtype == VCHR || vtype == VBLK) {
        panic("MacFUSE: buf_strategy: b_vp == NULL || vtype == VCHR | VBLK\n");
    }

    bflags = buf_flags(bp);

    if (bflags & B_READ) {
        bmap_flags = VNODE_READ;
    } else {
        bmap_flags = VNODE_WRITE;
    }

    bupl = buf_upl(bp);
    blkno = buf_blkno(bp);
    lblkno = buf_lblkno(bp);

    if (!(bflags & B_CLUSTER)) {

        if (bupl) {
            return (cluster_bp(bp));
        }

        if (blkno == lblkno) {
            off_t  f_offset;
            size_t contig_bytes;

            data = fuse_get_mpdata(vnode_mount(vp));

            // Still think this is a kludge?
            f_offset = lblkno * data->blocksize;
            blkno = f_offset / data->blocksize;

            buf_setblkno(bp, blkno);

            contig_bytes = buf_count(bp);

            if (blkno == -1) {
                buf_clear(bp);
            }
                        
            /*
             * Our "device" is always /all contiguous/. We don't wanna be
             * doing things like:
             *
             * ...
             *     else if ((long)contig_bytes < buf_count(bp)) {
             *         ret = buf_strategy_fragmented(devvp, bp, f_offset,
             *                                       contig_bytes));
             *         return ret;
             *      }
             */
        }

        if (blkno == -1) {
            buf_biodone(bp);
            return (0);
        }
    }

    // Issue the I/O

    return fuse_internal_strategy(vp, bp);
}

/* entity creation */

__private_extern__
void
fuse_internal_newentry_makerequest(mount_t                 mp,
                                   uint64_t                dnid,
                                   struct componentname   *cnp,
                                   enum fuse_opcode        op,
                                   void                   *buf,
                                   size_t                  bufsize,
                                   struct fuse_dispatcher *fdip,
                                   vfs_context_t           context)
{
    debug_printf("fdip=%p, context=%p\n", fdip, context);

    fdip->iosize = bufsize + cnp->cn_namelen + 1;

    fdisp_make(fdip, op, mp, dnid, context);
    memcpy(fdip->indata, buf, bufsize);
    memcpy((char *)fdip->indata + bufsize, cnp->cn_nameptr, cnp->cn_namelen);
    ((char *)fdip->indata)[bufsize + cnp->cn_namelen] = '\0';

    fdip->iosize = bufsize + cnp->cn_namelen + 1;

    fdisp_make(fdip, op, mp, dnid, context);
    memcpy(fdip->indata, buf, bufsize);
    memcpy((char *)fdip->indata + bufsize, cnp->cn_nameptr, cnp->cn_namelen);
    ((char *)fdip->indata)[bufsize + cnp->cn_namelen] = '\0';
}

__private_extern__
int
fuse_internal_newentry_core(vnode_t                 dvp,
                            vnode_t                *vpp,
                            struct componentname   *cnp,
                            enum vtype              vtyp,
                            struct fuse_dispatcher *fdip,
                            vfs_context_t           context)
{
    int err = 0;
    struct fuse_entry_out *feo;
    mount_t mp = vnode_mount(dvp);

    debug_printf("fdip=%p, context=%p\n", fdip, context);

    // Double-check that we aren't MNT_RDONLY?

    if ((err = fdisp_wait_answ(fdip))) {
        return (err);
    }
        
    feo = fdip->answ;

    if ((err = fuse_internal_checkentry(feo, vtyp))) {
        goto out;
    }

    err = fuse_vget_i(mp,
                      feo->nodeid,
                      context,
                      dvp,
                      vpp,
                      cnp,
                      vtyp,
                      FUSE_ZERO_SIZE,
                      VG_FORCENEW,
                      VTOI(dvp));
    if (err) {
        fuse_internal_forget_send(mp, context, feo->nodeid, 1, fdip);
        return err;
    }

    cache_attrs(*vpp, feo);

out:
    fuse_ticket_drop(fdip->tick);

    return err;
}

__private_extern__
int
fuse_internal_newentry(vnode_t               dvp,
                       vnode_t              *vpp,
                       struct componentname *cnp,
                       enum fuse_opcode      op,
                       void                 *buf,
                       size_t                bufsize,
                       enum vtype            vtype,
                       vfs_context_t         context)
{   
    int err;
    struct fuse_dispatcher fdi;
    mount_t mp = vnode_mount(dvp);
    
    debug_printf("context=%p\n", context);

    if (fuse_skip_apple_special_mp(mp, cnp->cn_nameptr, cnp->cn_namelen)) {
        return EACCES;
    }
    
    fdisp_init(&fdi, 0);
    fuse_internal_newentry_makerequest(mp, VTOI(dvp), cnp, op, buf,
                                       bufsize, &fdi, context);
    err = fuse_internal_newentry_core(dvp, vpp, cnp, vtype, &fdi, context);
    fuse_invalidate_attr(dvp);            
                   
    return (err);  
}         

/* entity destruction */

__private_extern__
int
fuse_internal_forget_callback(struct fuse_ticket *ftick, __unused uio_t uio)
{
    struct fuse_dispatcher fdi;

    debug_printf("ftick=%p, uio=%p\n", ftick, uio);

    fdi.tick = ftick;

    fuse_internal_forget_send(ftick->tk_data->mp, (vfs_context_t)0, 
        ((struct fuse_in_header *)ftick->tk_ms_fiov.base)->nodeid, 1, &fdi);

    return 0;
}

__private_extern__
void
fuse_internal_forget_send(mount_t                 mp,
                          vfs_context_t           context,
                          uint64_t                nodeid,
                          uint64_t                nlookup,
                          struct fuse_dispatcher *fdip)
{
    struct fuse_forget_in *ffi;

    debug_printf("mp=%p, context=%p, nodeid=%llx, nlookup=%lld, fdip=%p\n",
                 mp, context, nodeid, nlookup, fdip);

    /*
     * KASSERT(nlookup > 0, ("zero-times forget for vp #%llu",
     *         (long long unsigned) nodeid));
     */

    fdisp_init(fdip, sizeof(*ffi));
    fdisp_make(fdip, FUSE_FORGET, mp, nodeid, context);

    ffi = fdip->indata;
    ffi->nlookup = nlookup;

    fticket_invalidate(fdip->tick);
    fuse_insert_message(fdip->tick);
}

__private_extern__
void
fuse_internal_interrupt_send(struct fuse_ticket *ftick)
{
    struct fuse_dispatcher fdi;
    struct fuse_interrupt_in *fii;

    fdi.tick = ftick;
    fdisp_init(&fdi, sizeof(*fii));
    fdisp_make(&fdi, FUSE_INTERRUPT, ftick->tk_data->mp, (uint64_t)0,
               (vfs_context_t)0);
    fii = fdi.indata;
    fii->unique = ftick->tk_unique;
    fticket_invalidate(fdi.tick);
    fuse_insert_message(fdi.tick);
}

__private_extern__
void
fuse_internal_vnode_disappear(vnode_t vp, vfs_context_t context, int dorevoke)
{   
    int err = 0;

    fuse_vncache_purge(vp);

    if (dorevoke) {
        err = fuse_internal_revoke(vp, REVOKEALL, context);
        if (err) {
            IOLog("MacFUSE: disappearing act: revoke failed (%d)\n", err);
        }

        err = vnode_recycle(vp);
        if (err) {
            IOLog("MacFUSE: disappearing act: recycle failed (%d)\n", err);
        }
    }
}

/* fuse start/stop */

#if M_MACFUSE_ENABLE_INIT_TIMEOUT

__private_extern__
void
fuse_internal_thread_call_expiry_handler(void *param0, void *param1)
{
    (void)param1;
    int pid = 0;
    struct fuse_data *data = (struct fuse_data *)param0;
    fuse_lck_mtx_lock(data->callout_mtx);
    pid = data->daemonpid;
    fdata_kick_set(data);

    (void)KUNCUserNotificationDisplayNotice(
                                      0,             // noticeTimeout
                                      0,             // flags
                                      NULL,          // iconPath
                                      NULL,          // soundPath
                                      NULL,          // localizationPath
                                      data->volname, // alertHeader
                                      FUSE_INIT_TIMEOUT_NOTICE_MESSAGE,
                                      FUSE_INIT_TIMEOUT_DEFAULT_BUTTON_TITLE);

    fuse_lck_mtx_unlock(data->callout_mtx);

    if (pid) {
        proc_signal(pid, FUSE_POSTUNMOUNT_SIGNAL);
    }
}

#endif

__private_extern__
int
fuse_internal_init_callback(struct fuse_ticket *ftick, uio_t uio)
{
    int err = 0;
    struct fuse_data     *data = ftick->tk_data;
    struct fuse_init_out *fiio;

    if ((err = ftick->tk_aw_ohead.error)) {
        goto out;
    }

    if ((err = fticket_pull(ftick, uio))) {
        goto out;
    }

    fiio = fticket_resp(ftick)->base;

    /* XXX: Do we want to check anything further besides this? */
    if (fiio->major < 7) {
        debug_printf("userpace version too low\n");
        err = EPROTONOSUPPORT;
        goto out;
    }

    data->fuse_libabi_major = fiio->major;
    data->fuse_libabi_minor = fiio->minor;

    if (fuse_libabi_geq(data, 7, 5)) {
        if (fticket_resp(ftick)->len == sizeof(struct fuse_init_out)) {
            data->max_write = fiio->max_write;
        } else {
            err = EINVAL;
        }
    } else {
        /* Old fix values */
        data->max_write = 4096;
    }

out:
    fuse_ticket_drop(ftick);

    if (err) {
        fdata_kick_set(data);
    }

#if M_MACFUSE_ENABLE_INIT_TIMEOUT
    /* INIT_CALLOUT */
    fuse_lck_mtx_lock(data->callout_mtx);
    (void)thread_call_cancel(data->thread_call);
    data->callout_status = INIT_CALLOUT_INACTIVE;
    fuse_lck_mtx_unlock(data->callout_mtx);
#endif

    fuse_lck_mtx_lock(data->ticket_mtx);
    data->dataflags |= FSESS_INITED;
    fuse_wakeup(&data->ticketer);
    fuse_lck_mtx_unlock(data->ticket_mtx);

    return (0);
}

__private_extern__
void
fuse_internal_send_init(struct fuse_data *data, vfs_context_t context)
{
    struct fuse_init_in   *fiii;
    struct fuse_dispatcher fdi;

    fdisp_init(&fdi, sizeof(*fiii));
    fdisp_make(&fdi, FUSE_INIT, data->mp, 0, context);
    fiii = fdi.indata;
    fiii->major = FUSE_KERNEL_VERSION;
    fiii->minor = FUSE_KERNEL_MINOR_VERSION;
    fiii->max_readahead = data->iosize * 16;
    fiii->flags = 0;

#if M_MACFUSE_ENABLE_INIT_TIMEOUT
    {
        /* INIT_CALLOUT */
        uint64_t deadline;
        clock_interval_to_deadline(data->init_timeout.tv_sec, kSecondScale,
                                   &deadline);
        fuse_lck_mtx_lock(data->callout_mtx);
        thread_call_enter_delayed(data->thread_call, deadline);
        data->callout_status = INIT_CALLOUT_ACTIVE;
        fuse_lck_mtx_unlock(data->callout_mtx);
    }
#endif

    fuse_insert_callback(fdi.tick, fuse_internal_init_callback);
    fuse_insert_message(fdi.tick);
}
