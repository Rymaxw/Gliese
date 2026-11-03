#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;

$| = 1;
my ($dylib) = @ARGV;
die "usage: media-spike-probe.pl <path-to-libGlieseMediaSpike.dylib>\n"
    unless defined $dylib && -f $dylib;

my $handle = DynaLoader::dl_load_file($dylib, 0)
    or die "media-spike-probe: dl_load_file failed: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "gliese_media_spike_entry")
    or die "media-spike-probe: symbol missing: " . DynaLoader::dl_error() . "\n";

DynaLoader::dl_install_xsub("main::gliese_media_spike_run", $symbol);
gliese_media_spike_run();
