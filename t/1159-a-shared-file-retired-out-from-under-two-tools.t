#!/usr/bin/env perl
# TKT-1136. tools/gate-run and tools/dev-run both hardcoded
# docker-compose.testing.yml - a single compose file shared by every skill
# in the workspace, bind-mounting a live/scratch directory into a shared
# "perl-test" service. That file was retired (confirmed live, 2026-09-23:
# both tools failed immediately with "cannot find
# .../docker-compose.testing.yml" the instant it was deleted, for any
# commit, not a regression from either tool's own logic).
#
# Migrated to d2 docker compose instead - which needs a DISTINCT image per
# tool, since each builds from a different, changing directory on every
# invocation (gate-run's own scratch clone of HEAD; dev-run's own scratch
# copy of the working tree) and reusing one fixed image tag between them,
# or with the ordinary "test" service a normal dev build already uses,
# would race whichever else happened to be building at the same moment
# (Q-179/Q-181/Q-182, Michael's own answer: a distinct service folder gets
# a distinct image).
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $gate_run = File::Spec->catfile(qw(.developer-dashboard skills gate cli run));
my $dev_run  = File::Spec->catfile(qw(.developer-dashboard skills dev cli run));
ok( -f $gate_run, 'tools/gate-run exists' );
ok( -f $dev_run,  'tools/dev-run exists' );

my $gate_text = slurp($gate_run);
my $dev_text  = slurp($dev_run);

# --- neither tool's actual invocation depends on the retired file any more --
#
# Historical comments naming docker-compose.testing.yml (what it was, why
# it was retired) are fine and expected - this checks the FUNCTIONAL path,
# not every mention of the string.

unlike( $gate_text, qr/compose="\$workspace\/docker-compose\.testing\.yml"/,
    "gate-run's own \$compose variable no longer points at the retired file" );
unlike( $dev_text, qr/compose="\$workspace\/docker-compose\.testing\.yml"/,
    "dev-run's own \$compose variable no longer points at the retired file" );
unlike( $gate_text, qr/docker compose -f "\$compose"/,
    'gate-run no longer invokes docker compose against the retired file' );
unlike( $dev_text, qr/docker compose -f "\$compose"/,
    'dev-run no longer invokes docker compose against the retired file' );

# --- both now go through d2 docker compose, each its own distinct service --

like( $gate_text, qr/d2 docker compose --service "\$gate_service"/,
    "gate-run builds through d2 docker compose, its own \"gate\" service" );
like( $dev_text, qr/d2 docker compose --service "\$dev_service"/,
    "dev-run builds through d2 docker compose, its own \"dev\" service" );

# --- each has its own compose.yml/Dockerfile, with a genuinely distinct ----
# --- image and project name - not the ordinary "test" service's tira:latest,
# --- and not each other's -----------------------------------------------

for my $pair (
    [ gate => File::Spec->catfile(qw(.developer-dashboard config docker gate compose.yml)) ],
    [ dev  => File::Spec->catfile(qw(.developer-dashboard config docker dev  compose.yml)) ],
) {
    my ( $service, $path ) = @$pair;
    ok( -f $path, "the $service service has its own compose.yml" );
    my $compose_text = slurp($path);
    like( $compose_text, qr/^name:\s*tira-\Q$service\E\s*$/m,
        "the $service service declares its own distinct project name" );
    like( $compose_text, qr/image:\s*tira-\Q$service\E:latest/,
        "the $service service builds its own distinct image, not tira:latest" );
    my $dockerfile = File::Spec->catfile(qw(.developer-dashboard config docker), $service, 'Dockerfile');
    ok( -f $dockerfile, "the $service service has its own Dockerfile" );
}

# --- README's own documented incantation is not the retired one either -----

my $readme = slurp('README.md');
like( $readme, qr/## Verification/, 'README.md was actually read - its own Verification heading is present' );
unlike( $readme, qr/docker compose -f ~\/projects\/skills\/docker-compose\.testing\.yml/,
    "README.md's Verification section no longer documents the retired incantation" );

done_testing;

__END__

=head1 NAME

t/1159-a-shared-file-retired-out-from-under-two-tools.t - gate-run and
dev-run each build their own distinct image, not the retired shared
docker-compose.testing.yml

=head1 DESCRIPTION

TKT-1136. C<docker-compose.testing.yml> - a compose file shared by every
skill in the workspace, bind-mounting a live or scratch directory into a
shared C<perl-test> service - was retired. C<tools/gate-run> and
C<tools/dev-run> both hardcoded it, and both failed immediately once it
was gone, for any commit or working tree, not a regression from either
tool's own logic (confirmed live).

Migrated to C<d2 docker compose> instead - each tool through its own
service folder (C<.developer-dashboard/config/docker/{gate,dev}/
{compose.yml,Dockerfile}>), building a genuinely distinct image
(C<tira-gate:latest>, C<tira-dev:latest>) from whichever scratch directory
that invocation is actually testing. A single shared image tag - the
ordinary C<test> service's own C<tira:latest>, or one tool's service
reused by the other - would race a concurrent build of the same tag
elsewhere, which is exactly the collision Michael's own answer (Q-179/
Q-181/Q-182) said to avoid by giving each caller its own image identity.

=cut
