#!/usr/bin/perl

use strict;
use warnings;

use Test::NoWarnings;
use Test::More tests => 2;

BEGIN {
    use_ok('C4::Barcodes::preyymmddts');
}
