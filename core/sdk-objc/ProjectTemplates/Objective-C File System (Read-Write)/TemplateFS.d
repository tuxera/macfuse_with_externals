#!/usr/sbin/dtrace -s

#pragma D option quiet

macfuse_objc*:::delegate-entry 
/execname == "�PROJECTNAME�"/
{
    printf("%s: %s\n", probefunc, copyinstr(arg0));
}
