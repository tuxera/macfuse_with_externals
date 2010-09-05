/*
 * Copyright (C) 2006-2008 Google. All Rights Reserved.
 * Amit Singh <singh@>
 */

#include <sys/types.h>
#include <sys/malloc.h>

#include "fuse.h"
#include "fuse_internal.h"
#include "fuse_ipc.h"
#include "fuse_locking.h"
#include "fuse_node.h"
#include "fuse_sysctl.h"

static struct fuse_ticket *fticket_alloc(struct fuse_data *data);
static void                fticket_refresh(struct fuse_ticket *ftick);
static void                fticket_destroy(struct fuse_ticket *ftick);
static int                 fticket_wait_answer(struct fuse_ticket *ftick);
static __inline__ int      fticket_aw_pull_uio(struct fuse_ticket *ftick,
                                               uio_t uio);
static __inline__ void     fuse_push_freeticks(struct fuse_ticket *ftick);

static __inline__ struct fuse_ticket *
fuse_pop_freeticks(struct fuse_data *data);

static __inline__ void     fuse_push_allticks(struct fuse_ticket *ftick);
static __inline__ void     fuse_remove_allticks(struct fuse_ticket *ftick);
static struct fuse_ticket *fuse_pop_allticks(struct fuse_data *data);

static int             fuse_body_audit(struct fuse_ticket *ftick, size_t blen);
static __inline__ void fuse_setup_ihead(struct fuse_in_header *ihead,
                                        struct fuse_ticket    *ftick,
                                        uint64_t               nid,
                                        enum fuse_opcode       op,
                                        size_t                 blen,
                                        vfs_context_t          context);

static fuse_handler_t  fuse_standard_handler;

void
fiov_init(struct fuse_iov *fiov, size_t size)
{
    size_t msize = FU_AT_LEAST(size);

    fiov->len = 0;

    fiov->base = FUSE_OSMalloc(msize, fuse_malloc_tag);
    if (!fiov->base) {
        panic("MacFUSE: OSMalloc failed in fiov_init");
    }

    FUSE_OSAddAtomic(1, (SInt32 *)&fuse_iov_current);

    bzero(fiov->base, msize);

    fiov->allocated_size = msize;
    fiov->credit = fuse_iov_credit;
}

void
fiov_teardown(struct fuse_iov *fiov)
{
    FUSE_OSFree(fiov->base, fiov->allocated_size, fuse_malloc_tag);
    fiov->allocated_size = 0;

    FUSE_OSAddAtomic(-1, (SInt32 *)&fuse_iov_current);
}

void
fiov_adjust(struct fuse_iov *fiov, size_t size)
{
    if (fiov->allocated_size < size ||
        (fuse_iov_permanent_bufsize >= 0 &&
         fiov->allocated_size - size > fuse_iov_permanent_bufsize &&
             --fiov->credit < 0)) {

        fiov->base = FUSE_OSRealloc_nocopy(fiov->base, fiov->allocated_size,
                                           FU_AT_LEAST(size));
        if (!fiov->base) {
            panic("MacFUSE: realloc failed");
        }

        fiov->allocated_size = FU_AT_LEAST(size);
        fiov->credit = fuse_iov_credit;
    }

    fiov->len = size;
}

int
fiov_adjust_canfail(struct fuse_iov *fiov, size_t size)
{
    if (fiov->allocated_size < size ||
        (fuse_iov_permanent_bufsize >= 0 &&
         fiov->allocated_size - size > fuse_iov_permanent_bufsize &&
             --fiov->credit < 0)) {

        void *tmpbase = NULL;

        tmpbase = FUSE_OSRealloc_nocopy_canfail(fiov->base,
                                                fiov->allocated_size,
                                                FU_AT_LEAST(size));
        if (!tmpbase) {
            return ENOMEM;
        }

        fiov->base = tmpbase;
        fiov->allocated_size = FU_AT_LEAST(size);
        fiov->credit = fuse_iov_credit;
    }

    fiov->len = size;

    return 0;
}

void
fiov_refresh(struct fuse_iov *fiov)
{
    bzero(fiov->base, fiov->len);    
    fiov_adjust(fiov, 0);
}

static struct fuse_ticket *
fticket_alloc(struct fuse_data *data)
{
    struct fuse_ticket *ftick;

    ftick = (struct fuse_ticket *)FUSE_OSMalloc(sizeof(struct fuse_ticket),
                                                fuse_malloc_tag);
    if (!ftick) {
        panic("MacFUSE: OSMalloc failed in fticket_alloc");
    }

    FUSE_OSAddAtomic(1, (SInt32 *)&fuse_tickets_current);

    bzero(ftick, sizeof(struct fuse_ticket));

    ftick->tk_unique = data->ticketer++;
    ftick->tk_data = data;

    fiov_init(&ftick->tk_ms_fiov, sizeof(struct fuse_in_header));
    ftick->tk_ms_type = FT_M_FIOV;

    ftick->tk_aw_mtx = lck_mtx_alloc_init(fuse_lock_group, fuse_lock_attr);
    fiov_init(&ftick->tk_aw_fiov, 0);
    ftick->tk_aw_type = FT_A_FIOV;

    return ftick;
}

static __inline__
void
fticket_refresh(struct fuse_ticket *ftick)
{
    fiov_refresh(&ftick->tk_ms_fiov);
    ftick->tk_ms_bufdata = NULL;
    ftick->tk_ms_bufsize = 0;
    ftick->tk_ms_type = FT_M_FIOV;

    bzero(&ftick->tk_aw_ohead, sizeof(struct fuse_out_header));

    fiov_refresh(&ftick->tk_aw_fiov);
    ftick->tk_aw_errno = 0;
    ftick->tk_aw_bufdata = NULL;
    ftick->tk_aw_bufsize = 0;
    ftick->tk_aw_type = FT_A_FIOV;

    ftick->tk_flag = 0;
    ftick->tk_age++;
}

static void
fticket_destroy(struct fuse_ticket *ftick)
{
    fiov_teardown(&ftick->tk_ms_fiov);

    lck_mtx_free(ftick->tk_aw_mtx, fuse_lock_group);
    ftick->tk_aw_mtx = NULL;
    fiov_teardown(&ftick->tk_aw_fiov);

    FUSE_OSFree(ftick, sizeof(struct fuse_ticket), fuse_malloc_tag);

    FUSE_OSAddAtomic(-1, (SInt32 *)&fuse_tickets_current);
}

static int
fticket_wait_answer(struct fuse_ticket *ftick)
{
    int err = 0;
    struct fuse_data *data;

    fuse_lck_mtx_lock(ftick->tk_aw_mtx);

    if (fticket_answered(ftick)) {
        goto out;
    }

    data = ftick->tk_data;

    if (fdata_dead_get(data)) {
        err = ENOTCONN;
        fticket_set_answered(ftick);
        goto out;
    }

again:
    err = fuse_msleep(ftick, ftick->tk_aw_mtx, PCATCH, "fu_ans",
                      data->daemon_timeout_p);
    if (err == EAGAIN) { /* same as EWOULDBLOCK */

        kern_return_t kr;
        unsigned int rf;

        fuse_lck_mtx_lock(data->timeout_mtx);

        if (data->dataflags & FSESS_NO_ALERTS) {
            data->timeout_status = FUSE_DAEMON_TIMEOUT_DEAD;
            fuse_lck_mtx_unlock(data->timeout_mtx);
            goto alreadydead;
        }

        switch (data->timeout_status) {

        case FUSE_DAEMON_TIMEOUT_NONE:
            data->timeout_status = FUSE_DAEMON_TIMEOUT_PROCESSING;
            fuse_lck_mtx_unlock(data->timeout_mtx);
            break;

        case FUSE_DAEMON_TIMEOUT_PROCESSING:
            fuse_lck_mtx_unlock(data->timeout_mtx);
            goto again;
            break; /* NOTREACHED */

        case FUSE_DAEMON_TIMEOUT_DEAD:
            fuse_lck_mtx_unlock(data->timeout_mtx);
            goto alreadydead;
            break; /* NOTREACHED */

        default:
            IOLog("MacFUSE: invalid timeout status (%d)\n",
                  data->timeout_status);
            fuse_lck_mtx_unlock(data->timeout_mtx);
            goto again;
            break; /* NOTREACHED */
        }

        /*
         * We will "hang" while this is showing.
         */

#if M_MACFUSE_ENABLE_KUNC
        kr = KUNCUserNotificationDisplayAlert(
                 FUSE_DAEMON_TIMEOUT_ALERT_TIMEOUT,   // timeout
                 0,                                   // flags (stop alert)
                 NULL,                                // iconPath
                 NULL,                                // soundPath
                 NULL,                                // localizationPath
                 data->volname,                       // alertHeader
                 FUSE_DAEMON_TIMEOUT_ALERT_MESSAGE,
                 FUSE_DAEMON_TIMEOUT_DEFAULT_BUTTON_TITLE,
                 FUSE_DAEMON_TIMEOUT_ALTERNATE_BUTTON_TITLE,
                 FUSE_DAEMON_TIMEOUT_OTHER_BUTTON_TITLE,
                 &rf);
#else
        kr = KERN_FAILURE;
#endif

        if (kr != KERN_SUCCESS) {
            /* force ejection if we couldn't show the dialog */
            IOLog("MacFUSE: force ejecting (no response from user space %d)\n",
                  kr);
            rf = kKUNCOtherResponse;
        }

        fuse_lck_mtx_lock(data->timeout_mtx);
        switch (rf) {
        case kKUNCOtherResponse:     /* Force Eject      */
            data->timeout_status = FUSE_DAEMON_TIMEOUT_DEAD;
            fuse_lck_mtx_unlock(data->timeout_mtx);
            break;

        case kKUNCDefaultResponse:   /* Keep Trying      */
        case kKUNCAlternateResponse: /* Don't Warn Again */
        case kKUNCCancelResponse:    /* No Selection     */
            data->timeout_status = FUSE_DAEMON_TIMEOUT_NONE;
            if (rf == kKUNCAlternateResponse) {
                data->daemon_timeout_p = (struct timespec *)0;
            }
            fuse_lck_mtx_unlock(data->timeout_mtx);
            goto again;
            break; /* NOTREACHED */

        default:
            IOLog("MacFUSE: unknown response from alert panel (kr=%d, rf=%d)\n",
                  kr, rf);
            data->timeout_status = FUSE_DAEMON_TIMEOUT_DEAD;
            fuse_lck_mtx_unlock(data->timeout_mtx);
            break;
        }

alreadydead:
        if (!fdata_dead_get(data)) {
            fdata_set_dead(data);
        }
        err = ENOTCONN;
        fticket_set_answered(ftick);

        goto out;
    }

#if M_MACFUSE_ENABLE_INTERRUPT
    else if (err == EINTR) {
       /*
        * XXX: Stop gap! I really need to finish interruption plumbing.
        */
       fuse_internal_interrupt_send(ftick);
    }
#endif

out:
    fuse_lck_mtx_unlock(ftick->tk_aw_mtx);

    if (!(err || fticket_answered(ftick))) {
        IOLog("MacFUSE: requester was woken up but still no answer");
        err = ENXIO;
    }

    return err;
}

static __inline__
int
fticket_aw_pull_uio(struct fuse_ticket *ftick, uio_t uio)
{
    int err = 0;
    size_t len = (size_t)uio_resid(uio);

    if (len) {
        switch (ftick->tk_aw_type) {
        case FT_A_FIOV:
            err = fiov_adjust_canfail(fticket_resp(ftick), len);
            if (err) {
                fticket_set_killl(ftick);
                IOLog("MacFUSE: failed to pull uio (error=%d)\n", err);
                break;
            }
            err = uiomove(fticket_resp(ftick)->base, (int)len, uio);
            if (err) {
                IOLog("MacFUSE: FT_A_FIOV error is %d (%p, %ld, %p)\n",
                      err, fticket_resp(ftick)->base, len, uio);
            }
            break;

        case FT_A_BUF:
            ftick->tk_aw_bufsize = len;
            err = uiomove(ftick->tk_aw_bufdata, (int)len, uio);
            if (err) {
                IOLog("MacFUSE: FT_A_BUF error is %d (%p, %ld, %p)\n",
                      err, ftick->tk_aw_bufdata, len, uio);
            }
            break;

        default:
            panic("MacFUSE: unknown answer type for ticket %p", ftick);
        }
    }

    return err;
}

int
fticket_pull(struct fuse_ticket *ftick, uio_t uio)
{
    int err = 0;

    if (ftick->tk_aw_ohead.error) {
        return 0;
    }

    err = fuse_body_audit(ftick, (size_t)uio_resid(uio));
    if (!err) {
        err = fticket_aw_pull_uio(ftick, uio);
    }

    return err;
}

struct fuse_data *
fdata_alloc(struct proc *p)
{
    struct fuse_data *data;

    data = (struct fuse_data *)FUSE_OSMalloc(sizeof(struct fuse_data),
                                             fuse_malloc_tag);
    if (!data) {
        panic("MacFUSE: OSMalloc failed in fdata_alloc");
    }

    bzero(data, sizeof(struct fuse_data));

    data->mp            = NULL;
    data->rootvp        = NULLVP;
    data->mount_state   = FM_NOTMOUNTED;
    data->daemoncred    = kauth_cred_proc_ref(p);
    data->daemonpid     = proc_pid(p);
    data->dataflags     = 0;
    data->mountaltflags = 0ULL;
    data->noimplflags   = 0ULL;

    data->rwlock        = lck_rw_alloc_init(fuse_lock_group, fuse_lock_attr);
    data->ms_mtx        = lck_mtx_alloc_init(fuse_lock_group, fuse_lock_attr);
    data->aw_mtx        = lck_mtx_alloc_init(fuse_lock_group, fuse_lock_attr);
    data->ticket_mtx    = lck_mtx_alloc_init(fuse_lock_group, fuse_lock_attr);

    STAILQ_INIT(&data->ms_head);
    TAILQ_INIT(&data->aw_head);
    STAILQ_INIT(&data->freetickets_head);
    TAILQ_INIT(&data->alltickets_head);

    data->freeticket_counter = 0;
    data->deadticket_counter = 0;
    data->ticketer           = 0;

#if M_MACFUSE_EXCPLICIT_RENAME_LOCK
    data->rename_lock = lck_rw_alloc_init(fuse_lock_group, fuse_lock_attr);
#endif

    data->timeout_status = FUSE_DAEMON_TIMEOUT_NONE;
    data->timeout_mtx    = lck_mtx_alloc_init(fuse_lock_group, fuse_lock_attr);

#if M_MACFUSE_ENABLE_INTERIM_FSNODE_LOCK
    data->biglock        = fusefs_recursive_lock_alloc();
#endif

    return data;
}

void
fdata_destroy(struct fuse_data *data)
{
    struct fuse_ticket *ftick;

    lck_mtx_free(data->ms_mtx, fuse_lock_group);
    data->ms_mtx = NULL;

    lck_mtx_free(data->aw_mtx, fuse_lock_group);
    data->aw_mtx = NULL;

    lck_mtx_free(data->ticket_mtx, fuse_lock_group);
    data->ticket_mtx = NULL;

#if M_MACFUSE_EXPLICIT_RENAME_LOCK
    lck_rw_free(data->rename_lock, fuse_lock_group);
    data->rename_lock = NULL;
#endif

    data->timeout_status = FUSE_DAEMON_TIMEOUT_NONE;
    lck_mtx_free(data->timeout_mtx, fuse_lock_group);

#if M_MACFUSE_ENABLE_INTERIM_FSNODE_LOCK
    fusefs_recursive_lock_free(data->biglock);
#endif

    while ((ftick = fuse_pop_allticks(data))) {
        fticket_destroy(ftick);
    }

    kauth_cred_unref(&(data->daemoncred));

    lck_rw_free(data->rwlock, fuse_lock_group);

    FUSE_OSFree(data, sizeof(struct fuse_data), fuse_malloc_tag);
}

int
fdata_dead_get(struct fuse_data *data)
{
    return (data->dataflags & FSESS_DEAD);
}

void
fdata_set_dead(struct fuse_data *data)
{
    fuse_lck_mtx_lock(data->ms_mtx);
    if (fdata_dead_get(data)) { 
        fuse_lck_mtx_unlock(data->ms_mtx);
        return;
    }

    data->dataflags |= FSESS_DEAD;
    fuse_wakeup_one((caddr_t)data);
#if M_MACFUSE_ENABLE_DSELECT
    selwakeup((struct selinfo*)&data->d_rsel);
#endif /* M_MACFUSE_ENABLE_DSELECT */
    fuse_lck_mtx_unlock(data->ms_mtx);

    fuse_lck_mtx_lock(data->ticket_mtx);
    fuse_wakeup(&data->ticketer);
    fuse_lck_mtx_unlock(data->ticket_mtx);

    vfs_event_signal(&vfs_statfs(data->mp)->f_fsid, VQ_DEAD, 0);
}

static __inline__
void
fuse_push_freeticks(struct fuse_ticket *ftick)
{
    STAILQ_INSERT_TAIL(&ftick->tk_data->freetickets_head, ftick,
                       tk_freetickets_link);
    ftick->tk_data->freeticket_counter++;
}

static __inline__
struct fuse_ticket *
fuse_pop_freeticks(struct fuse_data *data)
{
    struct fuse_ticket *ftick;

    if ((ftick = STAILQ_FIRST(&data->freetickets_head))) {
        STAILQ_REMOVE_HEAD(&data->freetickets_head, tk_freetickets_link);
        data->freeticket_counter--;
    }

    if (STAILQ_EMPTY(&data->freetickets_head) &&
        (data->freeticket_counter != 0)) {
        panic("MacFUSE: ticket count mismatch!");
    }

    return ftick;
}

static __inline__
void
fuse_push_allticks(struct fuse_ticket *ftick)
{
    TAILQ_INSERT_TAIL(&ftick->tk_data->alltickets_head, ftick,
                      tk_alltickets_link);
}

static __inline__
void
fuse_remove_allticks(struct fuse_ticket *ftick)
{
    ftick->tk_data->deadticket_counter++;
    TAILQ_REMOVE(&ftick->tk_data->alltickets_head, ftick, tk_alltickets_link);
}

static struct fuse_ticket *
fuse_pop_allticks(struct fuse_data *data)
{
    struct fuse_ticket *ftick;

    if ((ftick = TAILQ_FIRST(&data->alltickets_head))) {
        fuse_remove_allticks(ftick);
    }

    return ftick;
}

struct fuse_ticket *
fuse_ticket_fetch(struct fuse_data *data)
{
    int err = 0;
    struct fuse_ticket *ftick;

    fuse_lck_mtx_lock(data->ticket_mtx);

    if (data->freeticket_counter == 0) {
        fuse_lck_mtx_unlock(data->ticket_mtx);
        ftick = fticket_alloc(data);
        if (!ftick) {
            panic("MacFUSE: ticket allocation failed");
        }
        fuse_lck_mtx_lock(data->ticket_mtx);
        fuse_push_allticks(ftick);
    } else {
        /* locked here */
        ftick = fuse_pop_freeticks(data);
        if (!ftick) {
            panic("MacFUSE: no free ticket despite the counter's value");
        }
    }

    if (!(data->dataflags & FSESS_INITED) && data->ticketer > 1) {
        err = fuse_msleep(&data->ticketer, data->ticket_mtx, PCATCH | PDROP,
                          "fu_ini", 0);
    } else {
        if ((fuse_max_tickets != 0) &&
            ((data->ticketer - data->deadticket_counter) > fuse_max_tickets)) {
            err = 1;
        }
        fuse_lck_mtx_unlock(data->ticket_mtx);
    }

    if (err) {
        fdata_set_dead(data);
    }

    return ftick;
}

void
fuse_ticket_drop(struct fuse_ticket *ftick)
{
    int die = 0;

    fuse_lck_mtx_lock(ftick->tk_data->ticket_mtx);

    if ((fuse_max_freetickets >= 0 &&
        fuse_max_freetickets <= ftick->tk_data->freeticket_counter) ||
        (ftick->tk_flag & FT_KILLL)) {
        die = 1;
    } else {
        fuse_lck_mtx_unlock(ftick->tk_data->ticket_mtx);
        fticket_refresh(ftick);
        fuse_lck_mtx_lock(ftick->tk_data->ticket_mtx);
    }

    /* locked here */

    if (die) {
        fuse_remove_allticks(ftick);
        fuse_lck_mtx_unlock(ftick->tk_data->ticket_mtx);
        fticket_destroy(ftick);
    } else {
        fuse_push_freeticks(ftick);
        fuse_lck_mtx_unlock(ftick->tk_data->ticket_mtx);
    }
}

void
fuse_ticket_kill(struct fuse_ticket *ftick)
{
    fuse_lck_mtx_lock(ftick->tk_data->ticket_mtx);
    fuse_remove_allticks(ftick);
    fuse_lck_mtx_unlock(ftick->tk_data->ticket_mtx);
    fticket_destroy(ftick);
}

void
fuse_ticket_drop_invalid(struct fuse_ticket *ftick)
{
    if (ftick->tk_flag & FT_INVAL) {
        fuse_ticket_drop(ftick);
    }
}

void
fuse_insert_callback(struct fuse_ticket *ftick, fuse_handler_t *handler)
{
    if (fdata_dead_get(ftick->tk_data)) {
        return;
    }

    ftick->tk_aw_handler = handler;

    fuse_lck_mtx_lock(ftick->tk_data->aw_mtx);
    fuse_aw_push(ftick);
    fuse_lck_mtx_unlock(ftick->tk_data->aw_mtx);
}

void
fuse_insert_message(struct fuse_ticket *ftick)
{
    if (ftick->tk_flag & FT_DIRTY) {
        panic("MacFUSE: ticket reused without being refreshed");
    }

    ftick->tk_flag |= FT_DIRTY;

    if (fdata_dead_get(ftick->tk_data)) {
        return;
    }

    fuse_lck_mtx_lock(ftick->tk_data->ms_mtx);
    fuse_ms_push(ftick);
    fuse_wakeup_one((caddr_t)ftick->tk_data);
#if M_MACFUSE_ENABLE_DSELECT
    selwakeup((struct selinfo*)&ftick->tk_data->d_rsel);
#endif /* M_MACFUSE_ENABLE_DSELECT */
    fuse_lck_mtx_unlock(ftick->tk_data->ms_mtx);
}

void
fuse_insert_message_head(struct fuse_ticket *ftick)
{
    if (ftick->tk_flag & FT_DIRTY) {
        panic("MacFUSE: ticket reused without being refreshed");
    }

    ftick->tk_flag |= FT_DIRTY;

    if (fdata_dead_get(ftick->tk_data)) {
        return;
    }

    fuse_lck_mtx_lock(ftick->tk_data->ms_mtx);
    fuse_ms_push_head(ftick);
    fuse_wakeup_one((caddr_t)ftick->tk_data);
#if M_MACFUSE_ENABLE_DSELECT
    selwakeup((struct selinfo*)&ftick->tk_data->d_rsel);
#endif /* M_MACFUSE_ENABLE_DSELECT */
    fuse_lck_mtx_unlock(ftick->tk_data->ms_mtx);
}

static int
fuse_body_audit(struct fuse_ticket *ftick, size_t blen)
{
    int err = 0;
    enum fuse_opcode opcode;

    if (fdata_dead_get(ftick->tk_data)) {
        return ENOTCONN;
    }

    opcode = fticket_opcode(ftick);

    switch (opcode) {
    case FUSE_LOOKUP:
        err = (blen == sizeof(struct fuse_entry_out)) ? 0 : EINVAL;
        break;

    case FUSE_FORGET:
        panic("MacFUSE: a handler has been intalled for FUSE_FORGET");
        break;

    case FUSE_GETATTR:
        err = (blen == sizeof(struct fuse_attr_out)) ? 0 : EINVAL;
        break;

    case FUSE_SETATTR:
        err = (blen == sizeof(struct fuse_attr_out)) ? 0 : EINVAL;
        break;

    case FUSE_GETXTIMES:
        err = (blen == sizeof(struct fuse_getxtimes_out)) ? 0 : EINVAL;
        break;

    case FUSE_READLINK:
        err = (PAGE_SIZE >= blen) ? 0 : EINVAL;
        break;

    case FUSE_SYMLINK:
        err = (blen == sizeof(struct fuse_entry_out)) ? 0 : EINVAL;
        break;

    case FUSE_MKNOD:
        err = (blen == sizeof(struct fuse_entry_out)) ? 0 : EINVAL;
        break;

    case FUSE_MKDIR:
        err = (blen == sizeof(struct fuse_entry_out)) ? 0 : EINVAL;
        break;

    case FUSE_UNLINK:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_RMDIR:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_RENAME:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_LINK:
        err = (blen == sizeof(struct fuse_entry_out)) ? 0 : EINVAL;
        break;

    case FUSE_OPEN:
        err = (blen == sizeof(struct fuse_open_out)) ? 0 : EINVAL;
        break;

    case FUSE_READ:
        err = (((struct fuse_read_in *)(
                (char *)ftick->tk_ms_fiov.base +
                        sizeof(struct fuse_in_header)
                  ))->size >= blen) ? 0 : EINVAL;
        break;

    case FUSE_WRITE:
        err = (blen == sizeof(struct fuse_write_out)) ? 0 : EINVAL;
        break;

    case FUSE_STATFS:
        if (fuse_libabi_geq(ftick->tk_data, 7, 4)) {
            err = (blen == sizeof(struct fuse_statfs_out)) ? 0 : EINVAL;
        } else {
            err = (blen == FUSE_COMPAT_STATFS_SIZE) ? 0 : EINVAL;
        }
        break;

    case FUSE_RELEASE:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_FSYNC:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_SETXATTR:
        /* TBD */
        break;

    case FUSE_GETXATTR:
        /* TBD */
        break;

    case FUSE_LISTXATTR:
        /* TBD */
        break;

    case FUSE_REMOVEXATTR:
        /* TBD */
        break;

    case FUSE_FLUSH:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_INIT:
        if (blen == sizeof(struct fuse_init_out) || blen == 8) {
            err = 0;
        } else {
            err = EINVAL;
        }
        break;

    case FUSE_OPENDIR:
        err = (blen == sizeof(struct fuse_open_out)) ? 0 : EINVAL;
        break;

    case FUSE_READDIR:
        err = (((struct fuse_read_in *)(
                (char *)ftick->tk_ms_fiov.base +
                        sizeof(struct fuse_in_header)
                  ))->size >= blen) ? 0 : EINVAL;
        break;

    case FUSE_RELEASEDIR:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_FSYNCDIR:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_GETLK:
        panic("MacFUSE: no response body format check for FUSE_GETLK");
        break;

    case FUSE_SETLK:
        panic("MacFUSE: no response body format check for FUSE_SETLK");
        break;

    case FUSE_SETLKW:
        panic("MacFUSE: no response body format check for FUSE_SETLKW");
        break;

    case FUSE_ACCESS:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_CREATE:
        err = (blen == sizeof(struct fuse_entry_out) +
                           sizeof(struct fuse_open_out)) ? 0 : EINVAL;
        break;

    case FUSE_INTERRUPT:
        /* TBD */
        break;

    case FUSE_BMAP:
        /* TBD */
        break;

    case FUSE_DESTROY:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_EXCHANGE:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    case FUSE_SETVOLNAME:
        err = (blen == 0) ? 0 : EINVAL;
        break;

    default:
        IOLog("MacFUSE: opcodes out of sync (%d)\n", opcode);
        panic("MacFUSE: opcodes out of sync (%d)", opcode);
    }

    return err;
}

static void
fuse_setup_ihead(struct fuse_in_header *ihead,
                 struct fuse_ticket    *ftick,
                 uint64_t               nid,
                 enum fuse_opcode       op,
                 size_t                 blen,
                 vfs_context_t          context)
{
    ihead->len = (uint32_t)(sizeof(*ihead) + blen);
    ihead->unique = ftick->tk_unique;
    ihead->nodeid = nid;
    ihead->opcode = op;

    if (context) {
        ihead->pid = vfs_context_pid(context);
        ihead->uid = vfs_context_ucred(context)->cr_uid;
        ihead->gid = vfs_context_ucred(context)->cr_gid;
    } else {
        /* XXX: could use more thought */
        ihead->pid = proc_pid((proc_t)current_proc());
        ihead->uid = kauth_cred_getuid(kauth_cred_get());
        ihead->gid = kauth_cred_getgid(kauth_cred_get());
    }
}

static int
fuse_standard_handler(struct fuse_ticket *ftick, uio_t uio)
{
    int err = 0;
    int dropflag = 0;

    err = fticket_pull(ftick, uio);

    fuse_lck_mtx_lock(ftick->tk_aw_mtx);

    if (fticket_answered(ftick)) {
        dropflag = 1;
    } else {
        fticket_set_answered(ftick);
        ftick->tk_aw_errno = err;
        fuse_wakeup(ftick);
    }

    fuse_lck_mtx_unlock(ftick->tk_aw_mtx);

    if (dropflag) {
        fuse_ticket_drop(ftick);
    }

    return err;
}

void
fdisp_make(struct fuse_dispatcher *fdip,
           enum fuse_opcode        op,
           mount_t                 mp,
           uint64_t                nid,
           vfs_context_t           context)
{
    struct fuse_data *data = fuse_get_mpdata(mp);

    if (fdip->tick) {
        fticket_refresh(fdip->tick);
    } else {
        fdip->tick = fuse_ticket_fetch(data);
    }

    if (fdip->tick == 0) {
        panic("MacFUSE: fuse_ticket_fetch() failed");
    }

    FUSE_DIMALLOC(&fdip->tick->tk_ms_fiov, fdip->finh,
                  fdip->indata, fdip->iosize);

    fuse_setup_ihead(fdip->finh, fdip->tick, nid, op, fdip->iosize, context);
}

int
fdisp_make_canfail(struct fuse_dispatcher *fdip,
                   enum fuse_opcode        op,
                   mount_t                 mp,
                   uint64_t                nid,
                   vfs_context_t           context)
{
    int failed = 0;
    struct fuse_iov *fiov = NULL;

    struct fuse_data *data = fuse_get_mpdata(mp);

    if (fdip->tick) {
        fticket_refresh(fdip->tick);
    } else {
        fdip->tick = fuse_ticket_fetch(data);
    }

    if (fdip->tick == 0) {
        panic("MacFUSE: fuse_ticket_fetch() failed");
    }

    fiov = &fdip->tick->tk_ms_fiov;

    failed = fiov_adjust_canfail(fiov,
                                 sizeof(struct fuse_in_header) + fdip->iosize);

    if (failed) {
        fuse_ticket_kill(fdip->tick);
        return failed;
    }

    fdip->finh = fiov->base;
    fdip->indata = (char *)(fiov->base) + sizeof(struct fuse_in_header);

    fuse_setup_ihead(fdip->finh, fdip->tick, nid, op, fdip->iosize, context);

    return 0;
}

void
fdisp_make_vp(struct fuse_dispatcher *fdip,
              enum fuse_opcode        op,
              vnode_t                 vp,
              vfs_context_t           context)
{
    return fdisp_make(fdip, op, vnode_mount(vp), VTOI(vp), context);
}

int
fdisp_make_vp_canfail(struct fuse_dispatcher *fdip,
                      enum fuse_opcode        op,
                      vnode_t                 vp,
                      vfs_context_t           context)
{
    return fdisp_make_canfail(fdip, op, vnode_mount(vp), VTOI(vp), context);
}

int
fdisp_wait_answ(struct fuse_dispatcher *fdip)
{
    int err = 0;

    fdip->answ_stat = 0;
    fuse_insert_callback(fdip->tick, fuse_standard_handler);
    fuse_insert_message(fdip->tick);

    if ((err = fticket_wait_answer(fdip->tick))) { /* interrupted */

#ifndef DONT_TRY_HARD_PREVENT_IO_IN_VAIN
        struct fuse_ticket *ftick;
        unsigned            age;
#endif

        fuse_lck_mtx_lock(fdip->tick->tk_aw_mtx);

        if (fticket_answered(fdip->tick)) {
            /* IPC: already answered */
            fuse_lck_mtx_unlock(fdip->tick->tk_aw_mtx);
            goto out;
        } else {
            /* IPC: explicitly setting to answered */
            age = fdip->tick->tk_age;
            fticket_set_answered(fdip->tick);
            fuse_lck_mtx_unlock(fdip->tick->tk_aw_mtx);
#ifndef DONT_TRY_HARD_PREVENT_IO_IN_VAIN
            fuse_lck_mtx_lock(fdip->tick->tk_data->aw_mtx);
            TAILQ_FOREACH(ftick, &fdip->tick->tk_data->aw_head, tk_aw_link) {
                if (ftick == fdip->tick) {
                    if (fdip->tick->tk_age == age) {
                        /* Succeeded preventing I/O in vain */
                        fdip->tick->tk_aw_handler = NULL;
                    }
                    break;
                }
            }

            fuse_lck_mtx_unlock(fdip->tick->tk_data->aw_mtx);
#endif
            return err;
        }
    }

    /* IPC was NOT interrupt */

    if (fdip->tick->tk_aw_errno) {

        /* Explicitly EIO-ing */

        err = EIO;
        goto out;
    }

    if ((err = fdip->tick->tk_aw_ohead.error)) {

        /* Explicitly setting status */

        fdip->answ_stat = err;
        goto out;
    }

    fdip->answ = fticket_resp(fdip->tick)->base;
    fdip->iosize = fticket_resp(fdip->tick)->len;

    return 0;

out:
    fuse_ticket_drop(fdip->tick);

    return err;
}
