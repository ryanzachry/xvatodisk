#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw/SEEK_SET/;
use Storable qw/store retrieve/;
use File::Temp;
use Getopt::Long;
use Pod::Usage;

use constant CHUNK_SIZE  => 1048576;
use constant SECTOR_SIZE => 512;

=head1 NAME

xvatodisk - Makes disks in a XVA file available for mounting read-only.

=head1 SYNOPSIS

xvatodisk -x </path/to/exported.xva> [-m </path/to/saved.map>]

=over

=item arguments:

  -h, --help     display this help
  -x, --xva      path to xva to use
  -m, --map      path to map of xva to use or save

=back

=head1 DESCRIPTION

=cut

my ($xva_file, $xva_map_file, $help);
my $opt = GetOptions(
	"xva|x=s" => \$xva_file,
	"map|m:s" => \$xva_map_file,
	"help|h"  => \$help
);

pod2usage(1) if (!$opt || $help || !defined($xva_file) || !-e $xva_file);

# Mapping the xva can take a while on large files, save the map.
$xva_map_file ||= $xva_file . "-map";
my $xva = (-e $xva_map_file) ? retrieve($xva_map_file) : make_xva_map($xva_file, $xva_map_file);

# There can be multiple disks in an xva.
my $disks_found = scalar keys %$xva;
die "No disks were found in $xva_file" if ($disks_found == 0);

# Only need 1 loop device for all the disks.
chomp(my $loop_dev = `losetup --find`);
system("losetup", "--read-only", $loop_dev, $xva_file);

for my $id (keys %$xva) {
	printf "Disk Ref:$id (%.02f GB) -> /dev/mapper/xva-$id\n", $#{$xva->{$id}} / 1024;
	
	my $tmp = File::Temp->new(TEMPLATE => "dmtable-XXXX", SUFFIX => ".map");
	print $tmp make_dmtable($xva->{$id}, $loop_dev);

	system("dmsetup", "--readonly", "create", "xva-$id", $tmp->filename);
	`partprobe /dev/mapper/xva-$id 2>&1 > /dev/null`;
}

# Try and close things out on ctrl-c.
$SIG{INT} = sub {
	print "\ncleaning up...\n";

	for my $id (keys %$xva) {
		for (`ls -fXr /dev/mapper/xva-$id*`) {
			chomp();
			system("dmsetup", "remove", $_);
		}
	}

	system("losetup", "--detach", $loop_dev);
	exit;
};

sleep 1 while 1;


#-------------------------------------------------------------------------------
# Returns a table for dmtable that maps the disks.
#-------------------------------------------------------------------------------
sub make_dmtable {
	my ($disk_map, $loop_dev) = @_;

	my $table        = "";
	my $sector       = 0;
	my $total_chunks = scalar(@$disk_map);

	for (my $chunk_num = 0; $chunk_num < $total_chunks; $chunk_num++) {		
		if (defined(my $chunk = $disk_map->[$chunk_num])) {
			# Offset is at ->[1], size at ->[0]
			# Checksum files follow each chunk preventing continuos data.
			$table .= sprintf "%i %i %s %s %i\n",
				$sector,   $chunk->[1] / SECTOR_SIZE, "linear", 
				$loop_dev, $chunk->[0] / SECTOR_SIZE;

			$sector += $chunk->[1] / SECTOR_SIZE;
		}
		else {
			# Map out a zero section, safe because the last chunk of a disk 
			# will always exist.
			my $empty_chunks = 1;
			$empty_chunks++ until (defined($disk_map->[++$chunk_num]));
			$chunk_num--;

			my $empty_sectors = $empty_chunks * (CHUNK_SIZE / SECTOR_SIZE);
			$table  .= sprintf "%i %i %s\n", $sector, $empty_sectors, "zero";
			$sector += $empty_sectors;
		}
	}

	return $table;
}


#-------------------------------------------------------------------------------
# Returns a hashref that maps out each disk in the xva and the location of
# every non-zero sized chunk of data.
#-------------------------------------------------------------------------------
sub make_xva_map {
	my ($xva_file, $xva_map_file) = @_;

   	open(my $fh, "<:raw", $xva_file);

   	my %xva;
   	my $xva_size = (stat $xva_file)[7];
   	my $offset   = 0;
   	while (my $hdr = read_tar_header($fh, $offset)) {
   		printf("  - indexing xva: %0.2f\r", ($offset * 100) / $xva_size);
   		$offset += 512;

   		# Ignore the empty chunks since this will be read only.
   		if ($hdr->{name} =~ m{^Ref:(\d+)/(\d+)\0+$} && $hdr->{size} != 0) {
	   		$xva{$1}[$2] = [$offset, $hdr->{size}];
   		}

   		$offset += $hdr->{size} + $hdr->{padding};
   	}

    close($fh);
    print "  indexing xva complete\n";
    print "  map saved to: $xva_map_file\n";
	store(\%xva, $xva_map_file);

    return \%xva;
}


#-------------------------------------------------------------------------------
# Returns a hashref with the tar header at $offset or the current file 
# position. Returns undef at the end of the tar. This will advance the file 
# position by 512 bytes.
#-------------------------------------------------------------------------------
sub read_tar_header {
    my ($fh, $offset) = @_;

    sysseek($fh, $offset, SEEK_SET) if (defined($offset));
    sysread($fh, my $tar, 512);

    # The last 1024+ bytes of a tar are 0 so a 0 for the filename 
    # should catch end of the tar.
    return undef if (ord(substr($tar, 0, 1)) == 0);

    # Numbers in the tar header are stored in ascii octal.
    my $size = oct(substr($tar, 124, 11));

    return {
        name    => substr($tar, 0, 99),
        size    => $size,
        padding => (($size + 511) & ~511) - $size,
    };
}