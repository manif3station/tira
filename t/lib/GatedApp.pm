package GatedApp;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(signed_in);

# The board went behind a login in TKT-004, and Tira::DashboardWeb now insists
# on being given the login providers - a server that forgot to wire them would
# otherwise serve an ungated board, which is exactly the accident the gate
# exists to prevent. So the requirement stays, and the tests that are about the
# board rather than the gate use this instead.
#
# It is a test double, not a bypass: it stands in for somebody who is already
# signed in, so those tests go on asking what they were always asking.
sub signed_in {
    return (
        login_page => sub { return '<!doctype html><p>sign in</p>' },
        login_start => sub { return '{"ok":true,"token":"test-session"}' },
        login_register => sub { return '{"ok":true,"token":"test-session","claimed":true}' },
        session_resume => sub { return '{"person":"tester"}' },
        session_peek => sub { return '{"person":"tester"}' },
        session_end => sub { return '{"ok":true}' },
        work_log => sub { return '[]' },
    );
}

1;

__END__

=head1 NAME

GatedApp - a signed-in stand-in for the dashboard tests

=head1 DESCRIPTION

The browser dashboard sits behind a login. Building the application without
the login providers is a deliberate failure, so that a real server cannot
accidentally be started without a gate. The tests that are about the board
itself - its dialog, its lists, its attachments, its links - are not about the
gate, so they use C<signed_in> to stand in for a person who has already signed
in and carry on asking what they were always asking.

=cut
