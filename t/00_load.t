#!/usr/bin/env perl
# ABSTRACT: Basic load test

use strict;
use warnings;
use Test2::Bundle::More;

ok(eval { require Langertha::Raider::CLI; 1 },            'load Langertha::Raider::CLI')            or diag $@;
ok(eval { require Langertha::Raider::FileTools; 1 }, 'load Langertha::Raider::FileTools') or diag $@;

can_ok('Langertha::Raider::CLI', qw( new run raid_f raider ));

my $server = Langertha::Raider::FileTools::build_file_tools_server();
isa_ok($server, 'MCP::Server');

done_testing;
