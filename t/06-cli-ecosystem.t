#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

BEGIN {
    if (${^TAINT}) {
        $ENV{PATH} = '/usr/bin:/bin';
        $ENV{TMPDIR} = '/tmp';
        delete @ENV{qw(IFS CDPATH ENV BASH_ENV PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
    }
}

use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(encode_utf8);
use IPC::Open3;
use JSON::PP qw(decode_json);
use Symbol qw(gensym);
use Test::More;

# Every check here runs a real command as a child process and reads what it
# wrote. IPC::Open3 cannot spawn one on the Windows lab - it fails before the
# first assertion with "Can't spawn-NOWAIT" - so there is nothing here that can
# run on that platform. Said plainly rather than left as a failing file: what
# these commands do is covered by the engine tests everywhere, and what is not
# covered there is the shape of a real invocation, which is exactly what cannot
# be had. TKT-035 owns finding out why.
if ( $^O eq 'MSWin32' ) {
    plan skip_all => 'this platform cannot spawn a child process through IPC::Open3';
}

sub command {
    my ( $environment, @command ) = @_;
    local @ENV{ keys %{$environment} } = values %{$environment};
    my $error = gensym;
    my $pid = open3( my $input, my $output, $error, @command );
    close $input;
    my $stdout = do { local $/; <$output> } // '';
    my $stderr = do { local $/; <$error> } // '';
    waitpid $pid, 0;
    return ( $? >> 8, $stdout, $stderr );
}

my $tmp_value = tempdir( CLEANUP => 1 );
$tmp_value =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe temp path';
my $tmp = $1;
my $root = File::Spec->catdir( $tmp, 'cli-full' );
$^X =~ /\A([^\x00-\x1f\x7f]+)\z/ or die 'Unsafe Perl path';
my @perl = ($1);
push @perl, '-I/root/perl5/lib/perl5' if ${^TAINT};

my ( $status, $out, $err ) = command( {}, @perl, 'skills/project/cli/create', '--name', 'CLI full', '--dir', $root, '-o', 'json' );
is( $status, 0, 'full CLI project created' );
my %env = ( TIRA_HOME => $root );

( $status, $out, $err ) = command( \%env, @perl, 'skills/project/skills/people/cli/add', '--id', 'ada', '--name', encode_utf8('Ada £'), '-o', 'json' );
is( decode_json($out)->{id}, 'ada', 'nested people command dispatches' );
is( decode_json($out)->{name}, 'Ada £', 'UTF-8 project metadata round-trips without warnings' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/column/cli/add', '--type', 'ticket', '--name', 'doing', '--after', 'backlog', '-o', 'json' );
is( decode_json($out)->{name}, 'doing', 'column command parses placement arguments' );

command( \%env, @perl, 'skills/sow/cli/create', '--title', 'SOW', '-o', 'json' );
command( \%env, @perl, 'skills/epic/cli/create', '--title', 'Epic', '-o', 'json' );
command( \%env, @perl, 'skills/ticket/cli/create', '--title', 'Ticket', '-o', 'json' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/hierarchy/cli/link', '--parent', 'SOW-001', '--child', 'EPC-001', '--bogus' );
isnt( $status, 0, 'unknown hierarchy option is rejected' );

( $status, $out, $err ) = command( \%env, @perl, 'skills/hierarchy/cli/link', '--parent', 'SOW-001', '--child', 'EPC-001', '-o', 'json' );
is( $status, 0, 'hierarchy link dispatches' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/assign/cli/add', '--ref', 'TKT-001', '--person', 'ada', '-o', 'json' );
is( decode_json($out)->{assignee}, 'ada', 'assignment command dispatches' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/comment/cli/add', '--ref', 'TKT-001', '--author', 'ada', '--text', 'CLI note', '-o', 'json' );
is( decode_json($out)->{body}, 'CLI note', 'comment command dispatches' );
my $currency_comment = ( 'Migration detail. ' x 2200 ) . 'Fire damage costs £523';
( $status, $out, $err ) = command(
    \%env, @perl, 'skills/comment/cli/add', '--ref', 'TKT-001', '--author', 'ada',
    '--text', encode_utf8($currency_comment), '-o', 'json',
);
is( $status, 0, 'long UTF-8 comment command succeeds' );
is( $err, '', 'long UTF-8 comment emits no wide-character warning' );
is( decode_json($out)->{body}, $currency_comment, 'long UTF-8 comment JSON output round-trips' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/ticket/cli/show', '--ref', 'TKT-001', '-o', 'json' );
is( decode_json($out)->{comments}[1]{body}, $currency_comment, 'persisted UTF-8 comment remains readable' );
( $status, $out, $err ) = command( \%env, @perl, 'skills/ticket/cli/move', '--ref', 'TKT-001', '--column', 'doing', '-o', 'json' );
is( decode_json($out)->{column}, 'doing', 'record movement command dispatches' );
( $status, $out, $err ) = command( \%env, @perl, 'cli/search', '--text', 'Ticket', '--type', 'ticket', '-o', 'json' );
is( scalar @{ decode_json($out)->{hits} }, 1, 'root search command dispatches with standard envelope' );
( $status, $out, $err ) = command( \%env, @perl, 'cli/dashboard', '--type', 'all', '-o', 'json' );
ok( exists decode_json($out)->{ticket}{doing}, 'root dashboard command dispatches' );

done_testing;

__END__

=head1 NAME

06-cli-ecosystem.t - Full dotted command dispatch acceptance tests

=head1 DESCRIPTION

Exercises representative root, nested, and entity-specific DD entrypoints with
their real command-line parser.

=cut
