#!/usr/bin/env perl
# A restore writes to the board it was given, or to nothing at all.
#
# tools/board-restore names its destination through the environment on every
# command. The dashboard replaces that value with the board the working
# directory belongs to, so a restore run from inside any project writes into
# that project instead. Measured rather than reasoned: restoring a one-card
# backup into an empty directory, from inside this skill, put a card on this
# board. The tool's own shifted-copy check caught it on the next line and
# refused - which is the only reason it stopped at one card, and that check
# exists for a different reason entirely.
#
# A restore is what somebody runs when a board is already lost. The likeliest
# place to run it from is another project's directory, which is exactly the
# case that misfires.
#
# Driven with a stub that lands somewhere else, because that is what the
# dashboard does and a test cannot install the dashboard.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);

my $tmp  = tempdir( CLEANUP => 1 );
my $tool = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'board-restore' ) );

# A backup with one card on it, in the shape the tool reads.
my $backup = File::Spec->catdir( $tmp, 'backup' );
mkdir $backup or die "$backup: $!";
{
    my %files = (
        'project.json' => '{"name":"Elsewhere","people":[{"id":"claude"}]}',
        'records.json' => '{"count":1,"records":[{"ref":"ELS-001","type":"ticket",'
          . '"title":"One card","column":"backlog"}]}',
    );
    for my $kind (qw(sow epic ticket)) {
        $files{"columns-$kind.json"} = '[{"name":"backlog"},{"name":"done"}]';
        $files{"refs-$kind.json"}    = '{"prefix":"ELS"}';
    }
    for my $name ( sort keys %files ) {
        open my $fh, '>', File::Spec->catfile( $backup, $name ) or die $!;
        print {$fh} $files{$name};
        close $fh;
    }
}

# A d2 that ignores the board it is told to use, which is what the dashboard
# does when the working directory belongs to a project.
my $stub = File::Spec->catdir( $tmp, 'bin' );
mkdir $stub or die "$stub: $!";
{
    my $path = File::Spec->catfile( $stub, 'd2' );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} <<'SH';
#!/usr/bin/env bash
# Answers as a board that is not the one asked for, and creates nothing where
# it was told to.
case "$1" in
  tira.project.show) echo '{"name":"Somewhere else"}' ;;
  *)                 echo '{"ok":true}' ;;
esac
SH
    close $fh;
    chmod 0755, $path or die "chmod: $!";
}

my $destination = File::Spec->catdir( $tmp, 'rebuilt' );

my $here = getcwd();
chdir $tmp or die "chdir: $!";
local $ENV{PATH} = $stub . ':' . $ENV{PATH};
my ( $status, $said ) = run_capturing( 'python3', $tool, $backup, $destination );
chdir $here or die "chdir back: $!";

isnt( $status, 0, 'a restore that cannot reach its destination is refused' );

# non-empty is the whole claim: a precondition for the two below, which would
# pass against a tool that said nothing at all.
like( $said, qr/\S/, 'and says something about it' );
like( $said, qr/Somewhere else|nothing was made|nothing has been written/i,
    'naming the board it was actually reaching, or that nothing was made where it was told' );

ok( !-e File::Spec->catdir( $destination, '.tira', 'project.yml' ),
    'and no board is left half-built at the destination' );

done_testing;

__END__

=head1 NAME

231-a-restore-that-knows-where-it-is.t - the board it was given, or nothing

=head1 DESCRIPTION

C<tools/board-restore> named its destination through the environment and the
dashboard replaces that with the board the working directory belongs to, so a
restore run from inside a project wrote into that project. It checks, before
writing anything, that the board it was told to build exists where it was told
to build it and answers to the name in the backup.

Driven with a stub that lands elsewhere, because that is what the dashboard
does and a test cannot install one.

=cut
