/*
 * main.c
 * �PROJECTNAME�
 *
 * Created by �FULLUSERNAME� on �DATE�.
 * Copyright �YEAR� �ORGANIZATIONNAME�. All rights reserved.
 *
 * Compile on the command line as follows:
 * gcc -o "�PROJECTNAME�" �PROJECTNAMEASIDENTIFIER�.c main.c -lfuse
 *     -D_FILE_OFFSET_BITS=64 -D__FreeBSD__=10 -DFUSE_USE_VERSION=26
 */
#include "fuse.h"

extern struct fuse_operations �PROJECTNAMEASIDENTIFIER�_operations;

int main(int argc, char* argv[], char* envp[], char** exec_path) {
  umask(0);
  return fuse_main(argc, argv, &�PROJECTNAMEASIDENTIFIER�_operations, NULL);
}
