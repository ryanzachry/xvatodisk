XVA to Disk
=========

This will allow you to mount (read only) the disks in an XVA, in place. It does 
so by mapping out the XVA and using device-mapper to make the device. 

You need dmsetup and partprobe installed, on Debian: 
    apt-get install dmsetup parted && modprobe dm_mod

XVA Format
----------


An XVA is just a tar with a structure of:

    ova.xml
    Ref:1234/
        00000000
        00000000.checksum
        00000010
        00000010.checksum
        ...
    Ref:567/
        00000000
        00000000.checksum
        ...

ova.xml describes the virtual machine. For every disk in the VM there is
a Ref:<\d+> directory. In that directory are 1 MB chunks (\d{8}) and an
SHA1 checksum for that chunk (\d{8}.checksum).

There will always be a first and last chunk for the disk. Gaps in the
numbering are for chunks that are empty. Sometimes there is a chunk with a
size of 0 but I haven't seen any that are in between 0 and 1048576 bytes.
