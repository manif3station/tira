#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use Test::More;

# This test runs the shipped entrypoint as a real program, so under taint mode
# it has to prove its own paths and environment clean first.
sub untaint {
    my ($value) = @_;
    $value =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe path '$value'";
    return $1;
}
local $ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
my $root = untaint( File::Spec->rel2abs('.') );
my $commands = File::Spec->catfile( $root, 'docs', 'commands.md' );
my $manual = File::Spec->catfile( $root, 'SKILLS.md' );

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

sub run_entrypoint {
    my ($name) = @_;
    my $script = File::Spec->catfile( $root, 'cli', $name );
    open my $pipe, '-|', untaint($^X), $script or die "Cannot run '$script': $!";
    my $out = do { local $/; <$pipe> };
    close $pipe;
    return ( $out, $? >> 8 );
}

ok( -x File::Spec->catfile( $root, 'cli', 'usage' ), 'the usage entrypoint ships executable' );

my ( $printed, $status ) = run_entrypoint('usage');
is( $status, 0, 'printing the command reference succeeds' );
is( $printed, slurp($commands), 'it prints docs/commands.md byte for byte' );
ok( length $printed > 500, 'and the reference is not empty' );

# The two manuals must lead to each other, or reaching one is a dead end.
my $skills = slurp($manual);
like( $skills, qr/tira\.usage/, 'the agent manual names the command reference' );
my ($skills_para) = grep { /tira\.usage/ } split /\n\n/, $skills;
like( $skills_para, qr/command reference/i, 'and says what it is for' );
my $reference = slurp($commands);
like( $reference, qr/tira\.skills/, 'the command reference names the agent manual' );

# The manual's secrecy rule applies to the cross-reference too.
my ($crossref) = $skills =~ /^([^\n]*tira\.usage[^\n]*)$/m;
unlike( $crossref, qr/--project|TIRA_HOME|\.tira\//,
    'the cross-reference discloses no project selection' );

# A missing file must fail loudly rather than printing nothing and exiting 0.
{
    my $script = File::Spec->catfile( $root, 'cli', 'usage' );
    my $body = slurp($script);
    like( $body, qr/\bdie\b/, 'the entrypoint dies rather than printing nothing when the file is unreadable' );
}

done_testing;

__END__

=head1 NAME

56-usage.t - DD-470 the command reference has a command of its own

=head1 DESCRIPTION

C<tira.skills> printed the agent manual, but the command reference could
only be read by somebody who already knew the file existed and where to
find it. Proves C<tira.usage> prints it byte for byte, and that each
manual names the other, so whichever one an agent reaches first leads
to the second rather than being a dead end.

=cut
