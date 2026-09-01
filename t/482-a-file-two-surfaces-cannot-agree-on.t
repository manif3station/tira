#!/usr/bin/env perl
# TKT-713. _attachment_content_type takes an extension and, since TKT-645,
# the stored path - so an extension in neither named list is decided by
# reading the file's first bytes rather than falling straight to
# application/octet-stream. Two callers pass the path; the browser's own
# attachment_fetch provider did not, so a file the card dialog correctly
# calls text/plain (via record_show's own content_type field) was served
# by the /attachment route as raw application/octet-stream, and as a
# download rather than shown inline.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
use Test::More;

use lib 'lib', 't/lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'attachments' );
my $tira = Tira->new( clock => sub { '2026-09-01T19:00:00+0100' } );
$tira->create_project( name => 'Sniff project', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->create_record( project => $root, type => 'ticket', title => 'Carrier' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( undef, undef, undef, $calls ) = browser_cli( 'dashboard.ticket', '--title', '-o', 'browser' );
my %providers = %{ $calls->[0] };

# --- a text file with an extension in neither named list -------------------

my $unlisted = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', author => 'ada',
    filename => 'notes.zzq', content => "plain readable text\nacross two lines\n",
);
my $record = $tira->record_show( project => $root, ref => 'TKT-001' );
my ($reference) = grep { $_->{sha} eq $unlisted->{sha} } @{ $record->{attachments} };
ok( $reference, 'the attachment is on the record' );

my $fetched = $providers{attachment_fetch}->( { ref => 'TKT-001', sha => $unlisted->{sha}, extension => 'zzq' } );
is( $fetched->{content_type}, 'text/plain; charset=UTF-8',
    'the /attachment route sniffs an unlisted extension the same way the record side already does' );
ok( $fetched->{inline}, 'and serves it inline rather than as a forced download' );

# --- a binary file of the same unlisted extension ---------------------------

my $binary = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', author => 'ada',
    filename => 'blob.zzq', content => pack( 'C*', 0 .. 255 ),
);
my $binary_fetch = $providers{attachment_fetch}->( { ref => 'TKT-001', sha => $binary->{sha}, extension => 'zzq' } );
is( $binary_fetch->{content_type}, 'application/octet-stream',
    'a binary file with the same unlisted extension still sniffs to octet-stream' );
ok( !$binary_fetch->{inline}, 'and is still served as a download' );

# --- named-list extensions are unaffected -----------------------------------

my $script = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', author => 'ada',
    filename => 'run.pl', content => "print \"hi\\n\";\n",
);
my $script_fetch = $providers{attachment_fetch}->( { ref => 'TKT-001', sha => $script->{sha}, extension => 'pl' } );
is( $script_fetch->{content_type}, 'text/plain; charset=UTF-8', 'a .pl file is answered from the named text list, unaffected' );

my $zip = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', author => 'ada', filename => 'bundle.zip', content => 'PK...',
);
my $zip_fetch = $providers{attachment_fetch}->( { ref => 'TKT-001', sha => $zip->{sha}, extension => 'zip' } );
is( $zip_fetch->{content_type}, 'application/octet-stream', 'a .zip file is answered from the named binary list, unaffected' );

done_testing;

__END__

=head1 NAME

t/482-a-file-two-surfaces-cannot-agree-on.t - the attachment route and the
record it serves from agree on what a file is

=head1 DESCRIPTION

C<_attachment_content_type> decides an extension in neither of its named
lists by reading the stored file's first bytes (TKT-645) - but only when
handed the stored path to read. The browser's C<attachment_fetch> provider
called it with the extension alone, so the route fell straight to
C<application/octet-stream> and forced a download for a file the card
dialog (reading C<record_show>'s own C<content_type>, computed with the
path) correctly called C<text/plain>. C<attachment_fetch> now looks the
stored path up the same way C<attachment_list> already does, so both
surfaces sniff the same bytes. TKT-713.

=cut
