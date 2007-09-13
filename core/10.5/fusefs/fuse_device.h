/*
 * Copyright (C) 2006-2007 Google. All Rights Reserved.
 * Amit Singh <singh@>
 */

#ifndef _FUSE_DEVICE_H_
#define _FUSE_DEVICE_H_

#include <sys/conf.h>
#include <miscfs/devfs/devfs.h>

struct fuse_softc;
typedef struct fuse_softc * fuse_softc_t;

struct fuse_data;

int fuse_devices_start(void);
int fuse_devices_stop(void);

int fuse_devices_kill(int unit, struct proc *p);
int fuse_devices_print_vnodes(int unit_flags, struct proc *p);

fuse_softc_t      fuse_softc_get(dev_t dev);

struct fuse_data *fuse_softc_get_data(fuse_softc_t fdev);
void              fuse_softc_set_data(fuse_softc_t fdev,
                                      struct fuse_data *data);

void              fuse_softc_close_finalize(fuse_softc_t fdev);

#endif /* _FUSE_DEVICE_H_ */
