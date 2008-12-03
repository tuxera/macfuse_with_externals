/*
 * �PROJECTNAMEASIDENTIFIER�.c
 * �PROJECTNAME�
 *
 * Created by �FULLUSERNAME� on �DATE�.
 * Copyright �YEAR� �ORGANIZATIONNAME�. All rights reserved.
 *
 */

#include <fuse.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

static int
�PROJECTNAMEASIDENTIFIER�_fgetattr(const char *path, struct stat *stbuf,
                  struct fuse_file_info *fi) {
  memset(stbuf, 0, sizeof(struct stat));
  
  if (strcmp(path, "/") == 0) { /* The root directory of our file system. */
    stbuf->st_mode = S_IFDIR | 0755;
    stbuf->st_nlink = 3;
    return 0;
  }
  return -ENOENT;
}

static int
�PROJECTNAMEASIDENTIFIER�_getattr(const char *path, struct stat *stbuf) {
  return �PROJECTNAMEASIDENTIFIER�_fgetattr(path, stbuf, NULL);
}

static int
�PROJECTNAMEASIDENTIFIER�_readlink(const char *path, char *buf, size_t size) {
  return -ENOENT;
}

static int
�PROJECTNAMEASIDENTIFIER�_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                 off_t offset, struct fuse_file_info *fi) {
  if (strcmp(path, "/") != 0) /* We only recognize the root directory. */
    return -ENOENT;
  
  filler(buf, ".", NULL, 0);           /* Current directory (.)  */
  filler(buf, "..", NULL, 0);          /* Parent directory (..)  */
  
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_mknod(const char *path, mode_t mode, dev_t rdev) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_mkdir(const char *path, mode_t mode) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_unlink(const char *path) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_rmdir(const char *path) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_symlink(const char *from, const char *to) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_rename(const char *from, const char *to) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_exchange(const char *path1, const char *path2, unsigned long options) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_link(const char *from, const char *to) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_fsetattr_x(const char *path, struct setattr_x *attr,
                    struct fuse_file_info *fi) {
  return -ENOENT;
}

static int
�PROJECTNAMEASIDENTIFIER�_setattr_x(const char *path, struct setattr_x *attr) {
  return -ENOENT;
}

static int
�PROJECTNAMEASIDENTIFIER�_getxtimes(const char *path, struct timespec *bkuptime,
                   struct timespec *crtime) {
  return -ENOENT;
}

static int
�PROJECTNAMEASIDENTIFIER�_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_open(const char *path, struct fuse_file_info *fi) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_read(const char *path, char *buf, size_t size, off_t offset,
              struct fuse_file_info *fi) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_write(const char *path, const char *buf, size_t size,
               off_t offset, struct fuse_file_info *fi) {
  return -ENOSYS;
}

static int
�PROJECTNAMEASIDENTIFIER�_statfs(const char *path, struct statvfs *stbuf) {
  int res;

  // TODO: Return real statvfs values for your file system.
  res = statvfs("/", stbuf);
  if (res == -1) {
    return -errno;
  }
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_flush(const char *path, struct fuse_file_info *fi) {
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_release(const char *path, struct fuse_file_info *fi) {
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_fsync(const char *path, int isdatasync, struct fuse_file_info *fi) {
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_setxattr(const char *path, const char *name, const char *value,
                  size_t size, int flags, uint32_t position) {
  return -ENOTSUP;
 }

static int
�PROJECTNAMEASIDENTIFIER�_getxattr(const char *path, const char *name, char *value, size_t size,
                  uint32_t position) {
  return -ENOATTR;
}

static int
�PROJECTNAMEASIDENTIFIER�_listxattr(const char *path, char *list, size_t size) {
  return 0;
}

static int
�PROJECTNAMEASIDENTIFIER�_removexattr(const char *path, const char *name) {
  return -ENOATTR;
}

void *
�PROJECTNAMEASIDENTIFIER�_init(struct fuse_conn_info *conn) {
  FUSE_ENABLE_XTIMES(conn);
  return NULL;
}

void
�PROJECTNAMEASIDENTIFIER�_destroy(void *userdata) {
  /* nothing */
}

struct fuse_operations �PROJECTNAMEASIDENTIFIER�_operations = {
  .init        = �PROJECTNAMEASIDENTIFIER�_init,
  .destroy     = �PROJECTNAMEASIDENTIFIER�_destroy,
  .getattr     = �PROJECTNAMEASIDENTIFIER�_getattr,
  .fgetattr    = �PROJECTNAMEASIDENTIFIER�_fgetattr,
/*  .access      = �PROJECTNAMEASIDENTIFIER�_access, */
  .readlink    = �PROJECTNAMEASIDENTIFIER�_readlink,
/*  .opendir     = �PROJECTNAMEASIDENTIFIER�_opendir, */
  .readdir     = �PROJECTNAMEASIDENTIFIER�_readdir,
/*  .releasedir  = �PROJECTNAMEASIDENTIFIER�_releasedir, */
  .mknod       = �PROJECTNAMEASIDENTIFIER�_mknod,
  .mkdir       = �PROJECTNAMEASIDENTIFIER�_mkdir,
  .symlink     = �PROJECTNAMEASIDENTIFIER�_symlink,
  .unlink      = �PROJECTNAMEASIDENTIFIER�_unlink,
  .rmdir       = �PROJECTNAMEASIDENTIFIER�_rmdir,
  .rename      = �PROJECTNAMEASIDENTIFIER�_rename,
  .link        = �PROJECTNAMEASIDENTIFIER�_link,
  .create      = �PROJECTNAMEASIDENTIFIER�_create,
  .open        = �PROJECTNAMEASIDENTIFIER�_open,
  .read        = �PROJECTNAMEASIDENTIFIER�_read,
  .write       = �PROJECTNAMEASIDENTIFIER�_write,
  .statfs      = �PROJECTNAMEASIDENTIFIER�_statfs,
  .flush       = �PROJECTNAMEASIDENTIFIER�_flush,
  .release     = �PROJECTNAMEASIDENTIFIER�_release,
  .fsync       = �PROJECTNAMEASIDENTIFIER�_fsync,
  .setxattr    = �PROJECTNAMEASIDENTIFIER�_setxattr,
  .getxattr    = �PROJECTNAMEASIDENTIFIER�_getxattr,
  .listxattr   = �PROJECTNAMEASIDENTIFIER�_listxattr,
  .removexattr = �PROJECTNAMEASIDENTIFIER�_removexattr,
  .exchange    = �PROJECTNAMEASIDENTIFIER�_exchange,
  .getxtimes   = �PROJECTNAMEASIDENTIFIER�_getxtimes,
  .setattr_x   = �PROJECTNAMEASIDENTIFIER�_setattr_x,
  .fsetattr_x  = �PROJECTNAMEASIDENTIFIER�_fsetattr_x,
};
