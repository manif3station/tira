package Tira::OnboardWeb;

use strict;
use warnings;

our $VERSION = '1.00';

use Encode qw(encode_utf8);
use Dancer2 appname => 'TiraOnboard';

# One disposable server, one form, one submission. No login (there is no
# project yet to sign into), no session, no polling - the whole point is that
# it stops existing once it has done its one job. $CREATE and $STOPPED are
# package globals rather than closures because Dancer2 routes are compiled
# once against the package, the same reason Tira::DashboardWeb's providers
# are globals too.
our $CREATE;
our $STOPPED = 0;
our $DEFAULTS = sub { {} };
our $INITIAL_DIR;
our $QUESTIONS = [];

sub _response_bytes {
    my ($content) = @_;
    return utf8::is_utf8($content) ? encode_utf8($content) : $content;
}

sub _escape {
    my ($value) = @_;
    $value = defined $value ? $value : '';
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    return $value;
}

my @FIELDS = (
    [ dir           => 'Project directory' ],
    [ name          => 'Project name' ],
    [ members       => 'People, comma separated' ],
    [ sow_prefix    => 'SOW reference prefix' ],
    [ epic_prefix   => 'Epic reference prefix' ],
    [ ticket_prefix => 'Ticket reference prefix' ],
    [ columns       => 'Columns, in order, comma separated' ],
    [ notify_after  => 'Minutes before a card counts as stuck (blank for never)' ],
    [ agent         => 'Coding agent to remind' ],
    [ session       => 'Session id of the agent to remind' ],
    [ collector     => 'Name for this project reminder job' ],
);

sub _render_form {
    my (%args) = @_;
    my $fields = $args{fields} // {};
    my $error_html = $args{error}
      ? '<p class="onboard-error">' . _escape( $args{error} ) . '</p>'
      : '';
    my $rows = join "\n", map {
        my ( $name, $label ) = @{$_};
        my $default = $name eq 'sow_prefix'    ? 'SOW'
          : $name eq 'epic_prefix'   ? 'EPC'
          : $name eq 'ticket_prefix' ? 'TKT'
          :                            '';
        my $value = _escape( $fields->{$name} // $default );
        qq{<label>$label <input name="$name" value="$value"></label>};
    } @FIELDS;
    my $question_rows = join "\n", map {
        my $question = $_;
        my $label    = _escape( $question->{text} ) . ' (' . join( ' or ', @{ $question->{options} } ) . ')';
        my $value    = _escape( $fields->{ $question->{id} } // '' );
        qq{<label>$label <input name="$question->{id}" value="$value"></label>};
    } @{$QUESTIONS};
    $rows = join "\n", grep { length } ( $rows, $question_rows );
    return <<"HTML";
<!doctype html>
<html><head><meta charset="utf-8"><title>Tira - Set up a project</title></head>
<body>
<h1>Set up a Tira project</h1>
$error_html
<form method="post" action="/">
$rows
<button type="submit">Create this project</button>
</form>
</body></html>
HTML
}

sub _render_thanks {
    my ($summary) = @_;
    my $name = _escape( $summary->{project}{name} // '' );
    return <<"HTML";
<!doctype html>
<html><head><meta charset="utf-8"><title>Tira - Project created</title></head>
<body>
<h1>Thank you for using Tira</h1>
<p>The project "$name" is set up.</p>
<p>Your role from here is to view and manage cards - run
<code>d2 tira.dashboard -o browser</code> to open the board in a
browser. Every <code>tira.&lt;command&gt;</code> is written for an agent to
run, but you are welcome to run them yourself too.</p>
<p>This onboarding session has finished and will not answer any further
requests.</p>
</body></html>
HTML
}

sub _stopped_response {
    status 503;
    content_type 'text/plain; charset=UTF-8';
    return _response_bytes("This onboarding session has already finished.\n");
}

# Mirrors _wizard_defaults' shape (arrayref members/columns, matching what
# _answers_from_params itself produces) back into the flat strings the form's
# text inputs render, the same conversion _project_wizard does implicitly by
# offering each stored value as an _ask() default.
sub _fields_from_defaults {
    my ($defaults) = @_;
    my %fields;
    $fields{name}    = $defaults->{name}    if defined $defaults->{name};
    $fields{members} = $defaults->{members}[0] if $defaults->{members};
    $fields{"${_}_prefix"} = $defaults->{"${_}_prefix"}
      for grep { defined $defaults->{"${_}_prefix"} } qw(sow epic ticket);
    $fields{columns} = $defaults->{columns}[0] if $defaults->{columns};
    $fields{$_} = $defaults->{$_}
      for grep { defined $defaults->{$_} } ( qw(notify_after agent session collector), map { $_->{id} } @{$QUESTIONS} );
    return \%fields;
}

sub _answers_from_params {
    my ($params) = @_;
    my @question_ids = map { $_->{id} } @{$QUESTIONS};
    my %fields = map { $_ => ( $params->{$_} // '' ) } ( map( { $_->[0] } @FIELDS ), @question_ids );

    # GET / already falls back to $INITIAL_DIR - the real directory this
    # session was launched for - when the field is empty. POST / used to
    # default straight to the literal string '.' instead, which resolves
    # to whatever directory the onboarding web SERVER PROCESS happens to
    # be running from at request time - no relationship to the session's
    # own intended project. Nothing marks the field required, so clearing
    # it (by accident, or trying to reset a pre-filled value) silently
    # created a project in the wrong place. Left undef rather than
    # defaulted here when neither source has one, so the caller can refuse
    # the same way it already refuses a failed $CREATE, instead of a
    # second silent default swallowing the first fix. TKT-776.
    my $dir = $fields{dir} ne '' ? $fields{dir} : $INITIAL_DIR;
    my %answers = ( dir => $dir, name => $fields{name} );
    $answers{members} = [ $fields{members} ] if $fields{members} ne '';
    $answers{"${_}_prefix"} = $fields{"${_}_prefix"}
      for grep { $fields{"${_}_prefix"} ne '' } qw(sow epic ticket);
    $answers{columns} = [ $fields{columns} ] if $fields{columns} ne '';
    $answers{$_} = $fields{$_}
      for grep { $fields{$_} ne '' } ( qw(notify_after agent session collector), @question_ids );
    return ( \%fields, \%answers );
}

get '/' => sub {
    return _stopped_response() if $STOPPED;
    content_type 'text/html; charset=UTF-8';
    my $dir = scalar( params->{dir} ) || $INITIAL_DIR;
    my $fields = defined $dir ? _fields_from_defaults( eval { $DEFAULTS->($dir) } || {} ) : {};
    $fields->{dir} = $dir if defined $dir;
    return _response_bytes( _render_form( fields => $fields ) );
};

post '/' => sub {
    return _stopped_response() if $STOPPED;
    content_type 'text/html; charset=UTF-8';
    my ( $fields, $answers ) = _answers_from_params( scalar params );

    # The field was cleared and this session was launched with no
    # directory of its own either - nothing left to fall back to. Refused
    # the same way a failed $CREATE already is, rather than reaching
    # $CREATE with an undef dir and letting whatever it does with that
    # stand in for a real refusal. TKT-776.
    if ( !defined $answers->{dir} || $answers->{dir} eq '' ) {
        status 422;
        return _response_bytes(
            _render_form( error => 'No project directory to use - the field is empty and this session has none of its own', fields => $fields ) );
    }

    my $summary = eval { $CREATE->($answers) };
    if ( !$summary ) {
        my $error = $@ || 'Could not create the project';
        $error =~ s/(?: at \S+ line \d+\.?)?\s*\z//s;
        status 422;
        return _response_bytes( _render_form( error => $error, fields => $fields ) );
    }
    $STOPPED = 1;
    return _response_bytes( _render_thanks($summary) );
};

sub build_psgi_app {
    my ( $class, %args ) = @_;
    die "Onboarding needs a create provider\n" if ref $args{create} ne 'CODE';
    $CREATE      = $args{create};
    $DEFAULTS    = ref $args{defaults} eq 'CODE' ? $args{defaults} : sub { {} };
    $INITIAL_DIR = $args{dir};
    $QUESTIONS   = ref $args{questions} eq 'ARRAY' ? $args{questions} : [];
    $STOPPED     = 0;
    return __PACKAGE__->to_app;
}

# The live server is single-process and single-connection by design - there
# are no workers to keep in sync, and nothing this serves lives past the one
# submission it exists for. Once that submission succeeds, a forked watchdog
# gives the response a moment to actually leave the socket and then kills the
# parent - the only reliable way to stop a synchronous PSGI server from
# inside the request that just finished it, since exiting before the response
# is written would mean nobody ever saw it.
sub serve {
    my ( $class, %args ) = @_;
    my $app = $class->build_psgi_app(
        create => $args{create}, defaults => $args{defaults}, dir => $args{dir}, questions => $args{questions},
    );
    require Plack::Runner;
    my $runner = Plack::Runner->new;
    $runner->parse_options(
        '--server', 'HTTP::Server::PSGI', '--host', $args{host}, '--port', $args{port},
        '--env', 'deployment',
    );
    my $wrapped = sub {
        my ($env) = @_;
        my $response = $app->($env);
        if ($STOPPED) {
            my $pid = fork();
            if ( defined $pid && $pid == 0 ) {
                sleep 1;
                kill 'TERM', getppid();
                exit 0;
            }
        }
        return $response;
    };
    # Never returns in practice: the process is stopped by the watchdog's
    # SIGTERM, not by run() finishing on its own, so there is no "after" for
    # a return value to answer to.
    return $runner->run($wrapped);
}

1;

__END__

=head1 NAME

Tira::OnboardWeb - a disposable, no-login Dancer2 form for tira.onboard -o browser

=head1 DESCRIPTION

One page, one C<POST /> route: renders every field the CLI wizard
(C<Tira::CLI::_project_wizard>) collects as a single form, validates and
creates the project through the same C<create> provider the CLI's onboarding
command already reaches (C<_invoke> for the C<onboard> command), and answers
with a thank-you page. A second request after a successful creation gets a
503 rather than a second form - the session is meant for exactly one
submission. C<GET /> pre-fills the form from whatever project already
exists at the given C<dir> (TKT-543), the same way the CLI wizard's own
C<_wizard_defaults> does, via the injectable C<defaults> coderef. The form
also offers C<notify_after>/C<agent>/C<session>/C<collector> and one field
per the injectable C<questions> arrayref's entries (shaped like
C<Tira-E<gt>onboarding_questions()>'s own return value), matching every
field the CLI wizard's guided flow collects (TKT-553).

=head1 METHODS

=head2 build_psgi_app

Accepts a C<create> coderef (called with a hashref of answers, expected to
either return a project summary or die with a validation message), an
optional C<dir> (the directory C<GET /> pre-fills from, and the fallback
C<POST /> uses when the submitted field is cleared - TKT-776), an optional
C<defaults> coderef (called with that directory, expected to return a
hashref shaped like C<Tira::CLI::_wizard_defaults>' own return value), and
an optional C<questions> arrayref (shaped like
C<Tira-E<gt>onboarding_questions()>'s own return value, one form field
rendered per entry) - and returns the Dancer2 PSGI application.

=head2 serve

Runs the application using C<host>, C<port>, C<create>, C<dir>, C<questions>, and
C<defaults>, on a single-process synchronous server so a successful
submission can stop it cleanly afterwards.

=cut
