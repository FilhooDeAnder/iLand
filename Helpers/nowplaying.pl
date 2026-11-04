#!/usr/bin/perl
# iLand: loads nowplaying.dylib into perl and runs it.
# Since macOS 15.4, MediaRemote gives the "now playing" data only to processes with an Apple signature.
# /usr/bin/perl has that signature. The app has not.
use strict;
use warnings;
use DynaLoader;

my $lib = $ARGV[0];
die "usage: nowplaying.pl <nowplaying.dylib> watch|toggle|next|previous|seek <seconds>\n" unless defined $lib && -f $lib;
my $handle = DynaLoader::dl_load_file($lib, 0) or die "nowplaying: " . DynaLoader::dl_error() . "\n";
my $entry = DynaLoader::dl_find_symbol($handle, "iland_nowplaying_main") or die "nowplaying: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::iland_nowplaying_main", $entry);
iland_nowplaying_main();
